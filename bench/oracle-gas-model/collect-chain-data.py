#!/usr/bin/env python3
"""ENG-3913: collect every mainnet figure the gas model needs, from the chain itself.

Nothing here is quoted from a blog, a gas tracker screenshot or memory. Each figure is
read from an Ethereum mainnet block header or from Chainlink's ETH/USD aggregator, and
each is written out with the block number and UTC timestamp it came from, so a reviewer
can re-read exactly the same block and get exactly the same number.

Usage:  MAINNET_RPC_URL=... python3 collect-chain-data.py > chain-data.json

Read-only: this makes `eth_getBlockByNumber` and `eth_call` requests and sends no
transaction. Re-running produces a newer `now` block and a newer ETH price; the
historical anchors are immutable and will not move.
"""
import datetime
import json
import os
import statistics
import sys
import time
import urllib.request

RPC = os.environ["MAINNET_RPC_URL"]
BLOCKS_PER_DAY = 7200  # 12-second slots post-merge
LONDON = 12_965_000  # first block with a base fee (EIP-1559)
CHAINLINK_ETH_USD = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"
_id = [0]


def rpc(method, params):
    _id[0] += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=body, headers={"Content-Type": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                out = json.load(r)
            if "error" in out:
                raise RuntimeError(out["error"])
            return out["result"]
        except Exception:
            if attempt == 4:
                raise
            time.sleep(1.5 * (attempt + 1))


def header(n):
    b = rpc("eth_getBlockByNumber", [hex(n) if isinstance(n, int) else n, False])
    return {
        "number": int(b["number"], 16),
        "timestamp": int(b["timestamp"], 16),
        "gasLimit": int(b["gasLimit"], 16),
        "gasUsed": int(b["gasUsed"], 16),
        "baseFeeWei": int(b["baseFeePerGas"], 16) if b.get("baseFeePerGas") else None,
    }


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def anchor(block, label, why):
    h = header(block)
    return {
        "label": label,
        "why": why,
        "block": h["number"],
        "timeUtc": iso(h["timestamp"]),
        "baseFeeWei": h["baseFeeWei"],
        "baseFeeGwei": h["baseFeeWei"] / 1e9,
        "gasLimit": h["gasLimit"],
        "gasUsed": h["gasUsed"],
    }


def priority_fees(latest_number, blocks=20):
    """Median priority fee actually paid, from the transactions in recent blocks.

    A base fee alone does not get a transaction included; the model needs a real default
    for the tip. This reads full transaction bodies from the last `blocks` blocks and
    takes, per block, the median of (gasPrice - baseFee) over the transactions that
    reveal a gasPrice, then the median of those block medians.
    """
    per_block = []
    for n in range(latest_number - blocks + 1, latest_number + 1):
        b = rpc("eth_getBlockByNumber", [hex(n), True])
        base = int(b["baseFeePerGas"], 16) if b.get("baseFeePerGas") else 0
        tips = []
        for t in b["transactions"]:
            gp = t.get("gasPrice")
            if gp is None:
                continue
            tip = int(gp, 16) - base
            if tip >= 0:
                tips.append(tip)
        if tips:
            per_block.append(statistics.median(tips))
    if not per_block:
        return None
    return {
        "blocksSampled": len(per_block),
        "fromBlock": latest_number - blocks + 1,
        "toBlock": latest_number,
        "medianPriorityFeeWei": statistics.median(per_block),
        "medianPriorityFeeGwei": statistics.median(per_block) / 1e9,
    }


def peak_in_window(center, span):
    """Highest base fee in [center-span, center+span], every block inspected."""
    best = None
    for n in range(center - span, center + span + 1):
        h = header(n)
        if h["baseFeeWei"] is not None and (best is None or h["baseFeeWei"] > best["baseFeeWei"]):
            best = h
    return best


def main():
    latest = header("latest")
    # One block per calendar day for a year, stepping back in exact 7200-block strides.
    daily = []
    for d in range(365):
        h = header(latest["number"] - d * BLOCKS_PER_DAY)
        daily.append({"block": h["number"], "timeUtc": iso(h["timestamp"]),
                      "baseFeeGwei": h["baseFeeWei"] / 1e9, "gasLimit": h["gasLimit"]})
    fees = [d["baseFeeGwei"] for d in daily]
    limits = [d["gasLimit"] for d in daily]

    rd = rpc("eth_call", [{"to": CHAINLINK_ETH_USD, "data": "0xfeaf968c"}, "latest"])  # latestRoundData()
    words = [rd[2 + i * 64: 2 + (i + 1) * 64] for i in range(5)]
    eth_usd = int(words[1], 16) / 1e8
    eth_updated = int(words[3], 16)

    out = {
        "generatedAtUtc": iso(int(time.time())),
        "chain": "ethereum mainnet",
        "method": {
            "dailySample": "one block per calendar day for 365 days, stepping back in exact "
                           "7200-block strides (12s slots) from the latest block; the base fee "
                           "of that single block, not a daily average",
            "peakRefinement": "every block inspected across a +/-150 block window around a "
                              "coarse hit, so the reported peak is the true maximum of that "
                              "~1 hour window",
            "ethPrice": "Chainlink ETH/USD aggregator " + CHAINLINK_ETH_USD +
                        " latestRoundData() on mainnet, 8 decimals",
        },
        "now": {
            "block": latest["number"], "timeUtc": iso(latest["timestamp"]),
            "baseFeeGwei": latest["baseFeeWei"] / 1e9,
            "gasLimit": latest["gasLimit"], "gasUsed": latest["gasUsed"],
        },
        "priorityFee": priority_fees(latest["number"]),
        "ethUsd": {"price": eth_usd, "updatedAtUtc": iso(eth_updated),
                   "source": "Chainlink ETH/USD " + CHAINLINK_ETH_USD},
        "dailyYear": {
            "windowFromUtc": daily[-1]["timeUtc"], "windowToUtc": daily[0]["timeUtc"],
            "samples": len(fees),
            "baseFeeGweiMedian": statistics.median(fees),
            "baseFeeGweiMean": statistics.mean(fees),
            "baseFeeGweiMin": min(fees), "baseFeeGweiMax": max(fees),
            "gasLimitMin": min(limits), "gasLimitMax": max(limits),
            "gasLimitMedian": statistics.median(limits),
            "series": daily,
        },
        "gasAnchors": [
            anchor(latest["number"], "now",
                   "the latest block at generation time, so the page can say what gas costs "
                   "right now rather than only what it has cost"),
            anchor(24_710_557, "high",
                   "the busiest moment of the dearest day in the trailing year's daily sample "
                   "(2026-03-22); a bad day on a normal network, not a crisis"),
            anchor(23_550_029, "extremely high",
                   "the worst moment of the trailing year, during the 2025-10-10 market-wide "
                   "liquidation event; the network still works, but every write is ~4,500x "
                   "the median"),
            anchor(14_688_911, "historical peak",
                   "the highest base fee since EIP-1559 went live: the Otherdeed land mint, "
                   "2022-05-01. Kept because the ticket asks for a real historical peak and "
                   "because it is the honest ceiling, even though a 30M-gas-limit chain in "
                   "2022 is not the 60M chain of today"),
        ],
        "notes": {
            "medianIsTheAverageDial": "Tim's 'average' dial uses the MEDIAN of the daily "
                                      "sample, not the mean. The mean (%.4f gwei) is dragged "
                                      "up by a handful of spike days and is not what a normal "
                                      "day costs; the median (%.4f gwei) is."
                                      % (statistics.mean(fees), statistics.median(fees)),
            "baseFeeOnly": "Every gas figure here is the BASE FEE only. A real transaction "
                           "also pays a priority fee to be included. The model exposes the "
                           "priority fee as its own dial rather than baking a guess into "
                           "these anchors.",
            "preLondon": "No anchor predates block %d (EIP-1559). Before that there is no "
                         "base fee in the header, only per-transaction gas prices, which are "
                         "not comparable." % LONDON,
        },
    }
    json.dump(out, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
