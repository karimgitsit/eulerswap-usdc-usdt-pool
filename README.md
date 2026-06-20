# Credit-amplified USDC/USDT EulerSwap pool

A minimal Foundry project that deploys a single **credit-amplified USDC/USDT EulerSwap V2 pool**
on Ethereum mainnet — a plain pool with a static fee and **no custom hook**. Credit amplification
comes purely from vault config (lending vaults + collateral enabled + leveraged virtual reserves),
not from any hook.

## Deployed (mainnet)

| | |
|---|---|
| **Pool** | [`0x2Cf734A241Ba6A036d09144a7A68053b15c2a8a8`](https://etherscan.io/address/0x2Cf734A241Ba6A036d09144a7A68053b15c2a8a8) |
| Euler account (owner) | `0x32507c0d4182F39e5CFc5C4BF51fC55D594eDa88` |
| USDC vault (eUSDC-2) | `0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9` |
| USDT vault (eUSDT-2) | `0x313603FA690301b0CaeEf8069c065862f9162162` |
| EulerSwap V2 factory | `0xD05213331221fAB8a3C387F2affBb605Bb04DF5F` |
| EVC | `0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383` |
| [Deploy tx](https://etherscan.io/tx/0x41ea19244db5a2d87e3682268bbd434b510cb7dddc2438d16e4d82df4c394237) | `0x41ea1924…c394237` |

### Pool parameters
- Virtual reserves: **$100M / side** (cosmetic depth above the real credit cap, so the curve never binds before borrow capacity does)
- Concentration: **`1e18`** — pure constant-sum, flat 1:1 quoting (max routing competitiveness, **zero slippage protection / max depeg exposure**)
- Fee: **0.01%** static, per direction (`fee0 = fee1 = 1e14`); protocol fee 0
- Prices: `1e18 : 1e18` (1:1 peg); no hook, no expiry

### How the leverage actually works
Real swappable depth is **not** the $100M virtual number — it is hard-capped by the account's
borrow capacity (EVC health check), i.e. `1/(1 - borrowLTV)`. With the cluster's **0.94 borrow LTV**
and ~$200 NAV, the real per-side depth is **~$3,233 (~16.7×)**. The 25× figure is the *liquidation*
LTV (0.96) edge and is not reachable without being liquidatable. `getLimits()` reports only an upper
bound (cash/caps/reserves) and does **not** apply LTV — see `test/ForkDeploy.t.sol`, which proves the
real cap and health factor by executing swaps on a mainnet fork.

> ⚠️ EulerSwap V2 pools are Uniswap V4 hooks: the CREATE2 pool address must encode the hook
> permission flags (`0x28A8` in the low 14 bits), so the deploy **mines a salt** for a valid address.

## Layout
- `script/DeployStablePool.s.sol` — broadcastable deploy: mines the salt, enables collateral,
  installs the operator, and deploys the pool (auto-routes through `EVC.call` for non-zero sub-accounts).
- `test/ForkDeploy.t.sol` — forked-mainnet dry run proving deploy + real depth + health factor,
  plus the sub-account EVC-routed deploy path.

## Setup
```shell
forge install foundry-rs/forge-std euler-xyz/euler-swap
```
(`remappings.txt` is committed and points at the vendored interfaces.)

## Dry run (always do this before broadcasting)
```shell
export MAINNET_RPC_URL="https://your-rpc"

# rigorous: deposits collateral on a fork, deploys, probes real depth + prints health factor
forge test --mc ForkDeploy -vv --fork-url $MAINNET_RPC_URL

# simulate the exact txs the deploy will broadcast (no --broadcast)
EULER_ACCOUNT=0xYourAccount \
forge script script/DeployStablePool.s.sol:DeployStablePool \
  --fork-url $MAINNET_RPC_URL --sender 0xYourOwner -vv
```

## Broadcast
Sign with your own keystore (`cast wallet import <name> --interactive`) or a hardware wallet —
**never** put a raw private key in a file or on the command line.
```shell
EULER_ACCOUNT=0xYourAccount \
forge script script/DeployStablePool.s.sol:DeployStablePool \
  --rpc-url $MAINNET_RPC_URL --account <name> --sender 0xYourOwner \
  --broadcast --slow
```

## Operating the pool
- **Pause:** `EVC.setAccountOperator(account, pool, false)` (stops quoting; debt remains until repaid).
- **Retune fee / concentration / reserves without redeploying:** `pool.reconfigure(dParams, initialState)`
  from the euler account (same pool address).

## Closing the position / withdrawing your cash
The position is leveraged — USDT supplied as collateral against a USDC debt — so you can't just
"withdraw": the health check blocks pulling collateral while the debt is open, and you don't hold the
USDC to repay outright. `script/ClosePool.s.sol` does the full unwind atomically with **no outside
capital**: pause the pool → (in one EVC batch, health deferred) pull all USDT collateral, swap it to
USDC on Uniswap v3, repay the USDC debt in full → withdraw the remaining ~equity to you → drop the
controller/collateral/operator. You end with your equity (~$equity) in USDC.

```shell
# 1) ALWAYS dry-run on a fork first — runs the exact close against your REAL live position:
forge test --mc ForkClose -vvv --fork-url $MAINNET_RPC_URL

# 2) Broadcast (sign with your own keystore/hardware wallet; never a raw key):
RECIPIENT=0xYourWallet \
forge script script/ClosePool.s.sol:ClosePool \
  --rpc-url $MAINNET_RPC_URL --account <name> --sender 0xYourOwner --broadcast --slow
```
The pool contract stays deployed but is inert once the account is empty (nothing to borrow against).
`track.py` quantifies what you'll recover (`NAV (equity)`). Slippage floor = repaying the full debt,
so the swap reverts rather than under-repaying.

This is leveraged and carries liquidation risk. Not financial advice.
