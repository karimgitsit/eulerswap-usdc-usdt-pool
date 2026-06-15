#!/usr/bin/env python3
"""Track volume served + fees earned + position PnL for the deployed EulerSwap pool.

Pure-python (stdlib only) JSON-RPC client: no `cast`/Foundry needed.

Usage:
    MAINNET_RPC_URL=https://your-rpc python3 script/track.py

Robust against the exact Swap-event layout: it fetches *all* logs emitted by the
pool since deploy and identifies swaps by matching candidate event signatures, so
it won't silently report zero if the ABI guess is slightly off.
"""
import concurrent.futures
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

RPC = os.environ.get("MAINNET_RPC_URL", "https://ethereum-rpc.publicnode.com")
POOL = "0x2Cf734A241Ba6A036d09144a7A68053b15c2a8a8"
ACCT = "0x32507c0d4182F39e5CFc5C4BF51fC55D594eDa88"
USDC_VAULT = "0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9"
USDT_VAULT = "0x313603FA690301b0CaeEf8069c065862f9162162"
DEPLOY_BLOCK = 25276348
INITIAL_USD = 200  # initial deposit, USD
CHUNK = 2000       # preferred eth_getLogs window; auto-shrinks to the RPC's cap
WORKERS = 12       # parallel eth_getLogs requests (helps when the cap is tiny)


# ---------------------------------------------------------------- keccak256
def keccak256(data: bytes) -> bytes:
    RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A,
          0x8000000080008000, 0x000000000000808B, 0x0000000080000001,
          0x8000000080008081, 0x8000000000008009, 0x000000000000008A,
          0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
          0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
          0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
          0x000000000000800A, 0x800000008000000A, 0x8000000080008081,
          0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
    ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
           [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
    MASK = (1 << 64) - 1

    def rol(x, n):
        return ((x << n) | (x >> (64 - n))) & MASK

    rate = 136  # bytes, for keccak256 (1088 bits)
    # pad (keccak padding: 0x01 ... 0x80)
    msg = bytearray(data)
    msg.append(0x01)
    while len(msg) % rate != 0:
        msg.append(0x00)
    msg[-1] ^= 0x80

    state = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        block = msg[off:off + rate]
        for i in range(rate // 8):
            lane = int.from_bytes(block[i * 8:i * 8 + 8], "little")
            state[i % 5][i // 5] ^= lane
        for rnd in range(24):
            C = [state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4] for x in range(5)]
            D = [C[(x - 1) % 5] ^ rol(C[(x + 1) % 5], 1) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    state[x][y] ^= D[x]
            B = [[0] * 5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    B[y][(2 * x + 3 * y) % 5] = rol(state[x][y], ROT[x][y])
            for x in range(5):
                for y in range(5):
                    state[x][y] = B[x][y] ^ ((~B[(x + 1) % 5][y]) & B[(x + 2) % 5][y])
            state[0][0] ^= RC[rnd]

    out = bytearray()
    for i in range(rate // 8):
        out += state[i % 5][i // 5].to_bytes(8, "little")
    return bytes(out[:32])


def selector(sig: str) -> str:
    return "0x" + keccak256(sig.encode()).hex()[:8]


def topic(sig: str) -> str:
    return "0x" + keccak256(sig.encode()).hex()


# ---------------------------------------------------------------- JSON-RPC
_id = 0


def rpc(method, params):
    global _id
    _id += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={
        "Content-Type": "application/json",
        # Some public RPCs (Cloudflare-fronted) 403 the default urllib UA.
        "User-Agent": "Mozilla/5.0 (track.py)",
    })
    for attempt in range(5):
        try:
            r = json.loads(urllib.request.urlopen(req, timeout=60).read())
            if "error" in r:
                raise RuntimeError(r["error"])
            return r["result"]
        except urllib.error.HTTPError as e:
            # Surface the provider's actual message (e.g. Alchemy range/size limits).
            try:
                body = json.loads(e.read())
                msg = body.get("error", body)
            except Exception:
                msg = f"HTTP {e.code}"
            err = RuntimeError(msg)
            if e.code in (429, 500, 502, 503, 504):
                if attempt == 4:
                    raise err      # rate-limit / transient: retry with backoff
                time.sleep(2 ** attempt)
                continue
            if 400 <= e.code < 500:
                raise err          # other client errors are deterministic, don't retry
            if attempt == 4:
                raise err
            time.sleep(2 ** attempt)
        except Exception:
            if attempt == 4:
                raise
            time.sleep(2 ** attempt)


def eth_call(to, data):
    return rpc("eth_call", [{"to": to, "data": data}, "latest"])


def addr_arg(a):
    return a.lower().replace("0x", "").rjust(64, "0")


def uint_arg(n):
    return hex(n)[2:].rjust(64, "0")


# ---------------------------------------------------------------- position
sel_balanceOf = selector("balanceOf(address)")
sel_convertToAssets = selector("convertToAssets(uint256)")
sel_debtOf = selector("debtOf(address)")


def call_uint(to, data):
    return int(eth_call(to, data), 16)


def supplied(vault):
    shares = call_uint(vault, sel_balanceOf + addr_arg(ACCT))
    return call_uint(vault, sel_convertToAssets + uint_arg(shares))


def debt(vault):
    return call_uint(vault, sel_debtOf + addr_arg(ACCT))


# ---------------------------------------------------------------- carry / APY
SECONDS_PER_YEAR = 31_556_952
sel_interestRate = selector("interestRate()")   # borrow rate, per-second, 1e27-scaled
sel_interestFee = selector("interestFee()")     # protocol cut of interest, 1e4-scaled
sel_cash = selector("cash()")
sel_totalBorrows = selector("totalBorrows()")


def vault_rates(vault):
    """Return (borrow_apy, supply_apy, utilization) for an EVK vault."""
    spy = call_uint(vault, sel_interestRate)                 # ray (1e27) per second
    borrow_apy = (1 + spy / 1e27) ** SECONDS_PER_YEAR - 1
    cash = call_uint(vault, sel_cash)
    borrows = call_uint(vault, sel_totalBorrows)
    util = borrows / (cash + borrows) if (cash + borrows) else 0.0
    fee = call_uint(vault, sel_interestFee) / 1e4            # e.g. 1000 -> 10%
    supply_apy = borrow_apy * util * (1 - fee)
    return borrow_apy, supply_apy, util


# ---------------------------------------------------------------- logs
def _logs_for(start, end):
    return rpc("eth_getLogs", [{
        "address": POOL,
        "fromBlock": hex(start),
        "toBlock": hex(end),
    }])


def _suggested_window(msg):
    """Some providers (Alchemy) reply with the largest range they'd accept,
    e.g. '... should work: [0x.., 0x..]'. Parse it to learn the cap."""
    m = re.search(r"\[(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\]", str(msg))
    if m:
        return max(1, int(m.group(2), 16) - int(m.group(1), 16) + 1)
    return None


def _learn_window(start, latest):
    """Find the largest block window the RPC will accept for eth_getLogs.
    Tries the WHOLE span first — most RPCs cap by result *size*, not block
    *count*, so a low-traffic pool comes back in a single request."""
    full = latest - start + 1
    for w in (full, 100_000, 10_000, 2000, 1000, 100, 10):
        if w > full:
            continue
        try:
            _logs_for(start, start + w - 1)
            return w
        except Exception as e:
            sug = _suggested_window(e)
            if sug:
                return sug
    return 1


def get_logs():
    latest = int(rpc("eth_blockNumber", []), 16)
    win = _learn_window(DEPLOY_BLOCK, latest)
    ranges = []
    s = DEPLOY_BLOCK
    while s <= latest:
        e = min(s + win - 1, latest)
        ranges.append((s, e))
        s = e + 1
    total = len(ranges)
    print(f"  scanning {latest - DEPLOY_BLOCK + 1:,} blocks in {total:,} window(s) "
          f"of {win:,} (RPC getLogs cap)…", file=sys.stderr)
    if total > 500:
        print(f"\n  [!] This RPC caps getLogs at a tiny {win}-block window, so the "
              f"sweep needs {total:,} requests and will likely hit rate limits.\n"
              f"      Re-run against a wider-range RPC, e.g.:\n"
              f"        MAINNET_RPC_URL='https://ethereum-rpc.publicnode.com' "
              f"python3 script/track.py\n", file=sys.stderr)

    logs = []
    done = 0
    workers = WORKERS if total > 1 else 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(_logs_for, a, b): (a, b) for a, b in ranges}
        for f in concurrent.futures.as_completed(futs):
            logs.extend(f.result())
            done += 1
            if total > 1 and (done % 100 == 0 or done == total):
                print(f"  …{done:,}/{total:,} windows", file=sys.stderr)
    return logs, latest


def words(hexdata):
    h = hexdata[2:]
    return [int(h[i * 64:(i + 1) * 64], 16) for i in range(len(h) // 64)]


# Candidate Swap signatures (V2 carries fees; V1 is Uniswap-style). Keyed by
# how many non-indexed (data) words each emits.
SWAP_SIGS = {
    # sender(indexed), a0In,a1In,a0Out,a1Out,fee0,fee1, reserve0,reserve1, to(indexed)
    topic("Swap(address,uint256,uint256,uint256,uint256,uint256,uint256,uint112,uint112,address)"):
        {"words": 8, "fees": True},
    # Uniswap-style: sender(indexed), a0In,a1In,a0Out,a1Out, reserve0,reserve1, to(indexed)
    topic("Swap(address,uint256,uint256,uint256,uint256,uint112,uint112,address)"):
        {"words": 6, "fees": False},
}


def main():
    print(f"RPC: {RPC.split('/v2/')[0]}…\n")

    usdc_sup, usdt_sup = supplied(USDC_VAULT), supplied(USDT_VAULT)
    usdc_debt, usdt_debt = debt(USDC_VAULT), debt(USDT_VAULT)
    nav = (usdc_sup - usdc_debt) + (usdt_sup - usdt_debt)
    print("=== Position / PnL ===")
    print(f"USDC: supplied {usdc_sup/1e6:>14,.4f}  debt {usdc_debt/1e6:,.4f}")
    print(f"USDT: supplied {usdt_sup/1e6:>14,.4f}  debt {usdt_debt/1e6:,.4f}")
    print(f"NAV (equity)   = ${nav/1e6:,.4f}")
    print(f"PnL (stables)  = ${(nav - INITIAL_USD*10**6)/1e6:+,.4f}   (excludes ETH gas)")

    # ---- Carry economics: does the leveraged inventory pay or bleed? ----
    try:
        ub, us, uu = vault_rates(USDC_VAULT)
        tb, ts, tu = vault_rates(USDT_VAULT)
        income = (usdc_sup * us + usdt_sup * ts) / 1e6
        cost = (usdc_debt * ub + usdt_debt * tb) / 1e6
        net = income - cost
        print("\n=== Carry economics (live vault APYs) ===")
        print(f"USDC vault: borrow {ub*100:5.2f}%  supply {us*100:5.2f}%  (util {uu*100:4.1f}%)")
        print(f"USDT vault: borrow {tb*100:5.2f}%  supply {ts*100:5.2f}%  (util {tu*100:4.1f}%)")
        print(f"supply income  = +${income:,.2f}/yr")
        print(f"borrow cost    = -${cost:,.2f}/yr")
        nav_usd = nav / 1e6
        pct = (net / nav_usd * 100) if nav_usd else 0.0
        verdict = "POSITIVE — scaling volume scales profit" if net >= 0 else \
                  "NEGATIVE — scaling volume scales losses (fix before growing)"
        print(f"net carry      = ${net:+,.2f}/yr  ({pct:+.2f}% of NAV)  [pre-swap-fees]  -> {verdict}")
    except Exception as e:
        print(f"\n[carry economics unavailable: {e}]")

    logs, latest = get_logs()
    by_topic = {}
    for lg in logs:
        t0 = lg["topics"][0] if lg["topics"] else "(anon)"
        by_topic[t0] = by_topic.get(t0, 0) + 1

    v_usdc = v_usdt = f_usdc = f_usdt = nswaps = 0
    matched = False
    for lg in logs:
        t0 = lg["topics"][0] if lg["topics"] else None
        meta = SWAP_SIGS.get(t0)
        if not meta:
            continue
        matched = True
        w = words(lg["data"])
        if len(w) < 4:
            continue
        nswaps += 1
        v_usdc += w[0] + w[2]   # amount0In + amount0Out
        v_usdt += w[1] + w[3]   # amount1In + amount1Out
        if meta["fees"] and len(w) >= 6:
            f_usdc += w[4]
            f_usdt += w[5]

    print(f"\n=== Volume served (blocks {DEPLOY_BLOCK}..{latest}) ===")
    print(f"swaps          = {nswaps}")
    print(f"USDC volume    = ${v_usdc/1e6:,.2f}")
    print(f"USDT volume    = ${v_usdt/1e6:,.2f}")
    print(f"total volume   = ${(v_usdc+v_usdt)/1e6:,.2f}")
    if f_usdc or f_usdt:
        print(f"fees (events)  = ${(f_usdc+f_usdt)/1e6:,.4f}  (USDC {f_usdc/1e6:.4f} + USDT {f_usdt/1e6:.4f})")
    else:
        # Fee not in event ABI: derive from the 0.01%/side static fee on volume.
        est = (v_usdc + v_usdt) * 1e14 / 1e18
        print(f"fees (est @1bp)= ${est/1e6:,.4f}  (event carries no fee field; estimated from volume)")

    if not matched and logs:
        print("\n[!] No log matched a known Swap signature. Topic histogram:")
        for t, c in sorted(by_topic.items(), key=lambda x: -x[1]):
            print(f"    {t}  x{c}")
        print("    -> inspect the pool ABI and add the correct Swap signature to SWAP_SIGS.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
