#!/usr/bin/env bash
# Track volume served + position PnL for the deployed EulerSwap pool.
# Usage:  MAINNET_RPC_URL=https://your-rpc ./script/track.sh
# (falls back to a public RPC; for large block ranges use a private RPC e.g. Alchemy/Infura)
set -euo pipefail

RPC="${MAINNET_RPC_URL:-https://ethereum-rpc.publicnode.com}"
POOL="0x2Cf734A241Ba6A036d09144a7A68053b15c2a8a8"
ACCT="0x32507c0d4182F39e5CFc5C4BF51fC55D594eDa88"
USDC_VAULT="0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9"
USDT_VAULT="0x313603FA690301b0CaeEf8069c065862f9162162"
DEPLOY_BLOCK=25276348
INITIAL_USD=200          # initial deposit, USD

call() { cast call "$1" "$2" "$3" --rpc-url "$RPC" | awk '{print $1}'; }

# ---- Position / PnL (from current vault state) ----
USDC_SUP=$(call "$USDC_VAULT" "convertToAssets(uint256)(uint256)" "$(call "$USDC_VAULT" 'balanceOf(address)(uint256)' "$ACCT")")
USDT_SUP=$(call "$USDT_VAULT" "convertToAssets(uint256)(uint256)" "$(call "$USDT_VAULT" 'balanceOf(address)(uint256)' "$ACCT")")
USDC_DEBT=$(call "$USDC_VAULT" "debtOf(address)(uint256)" "$ACCT")
USDT_DEBT=$(call "$USDT_VAULT" "debtOf(address)(uint256)" "$ACCT")

# ---- Volume / fees (from Swap events) ----
TOPIC=$(cast keccak "Swap(address,uint256,uint256,uint256,uint256,uint256,uint256,uint112,uint112,address)")
FROM_HEX=$(cast 2h "$DEPLOY_BLOCK")
LOGS=$(cast rpc eth_getLogs \
  "{\"address\":\"$POOL\",\"topics\":[\"$TOPIC\"],\"fromBlock\":\"$FROM_HEX\",\"toBlock\":\"latest\"}" \
  --rpc-url "$RPC")

python3 - "$USDC_SUP" "$USDT_SUP" "$USDC_DEBT" "$USDT_DEBT" "$INITIAL_USD" "$LOGS" <<'PY'
import sys, json
usdc_sup, usdt_sup, usdc_debt, usdt_debt, init = (int(x) for x in sys.argv[1:6])
logs = json.loads(sys.argv[6])

nav = (usdc_sup - usdc_debt) + (usdt_sup - usdt_debt)   # 6dp, stables ~ $1
print("=== Position / PnL ===")
print(f"USDC: supplied {usdc_sup/1e6:>14,.4f}  debt {usdc_debt/1e6:,.4f}")
print(f"USDT: supplied {usdt_sup/1e6:>14,.4f}  debt {usdt_debt/1e6:,.4f}")
print(f"NAV (equity)   = ${nav/1e6:,.4f}")
print(f"PnL (stables)  = ${(nav - init*10**6)/1e6:+,.4f}   (excludes ETH gas)")

# decode 8 non-indexed words: a0In,a1In,a0Out,a1Out,fee0,fee1,r0,r1
def words(data):
    h = data[2:]
    return [int(h[i*64:(i+1)*64], 16) for i in range(len(h)//64)]
v_usdc = v_usdt = f_usdc = f_usdt = 0
for lg in logs:
    w = words(lg["data"])
    v_usdc += w[0] + w[2]      # amount0In + amount0Out
    v_usdt += w[1] + w[3]      # amount1In + amount1Out
    f_usdc += w[4]; f_usdt += w[5]
print("\n=== Volume served ===")
print(f"swaps          = {len(logs)}")
print(f"USDC volume    = ${v_usdc/1e6:,.2f}")
print(f"USDT volume    = ${v_usdt/1e6:,.2f}")
print(f"total volume   = ${(v_usdc+v_usdt)/1e6:,.2f}")
print(f"fees earned    = ${(f_usdc+f_usdt)/1e6:,.4f}  (USDC {f_usdc/1e6:.4f} + USDT {f_usdt/1e6:.4f})")
PY
