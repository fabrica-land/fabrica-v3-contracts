#!/usr/bin/env python3
"""ENG-4342: read the SHIPPED batched writes of the round-3 fact store off Sepolia.

Everything the model page shows under "shipped" comes from here, and every figure is read
from a Sepolia block, a transaction receipt or the transaction's own calldata. Nothing is
copied from a lane report, a Linear comment or a log line: the keeper's own
`oracle.write.batch` log says 24 facts at 75,597 gas per fact, and this script re-derives
both numbers from the chain rather than trusting that claim.

What it reads, and how
  1. Every log the store has emitted since its deployment block, in one `eth_getLogs`.
     That yields the set of transactions that touched the store, because every mutating
     function on `FabricaFactStore` emits exactly one event per unit of work.
  2. For each of those transactions: `eth_getTransactionByHash` (sender, nonce, calldata)
     and `eth_getTransactionReceipt` (gas used, effective gas price, status, logs).
  3. The fact count per transaction is decoded from the `writeFacts` calldata — the
     length of the `FactInput[]` array — AND counted from the `FactWritten` logs in the
     receipt. The two must agree or the script exits non-zero. A batch size is the one
     figure everything else on the page divides by, so it is measured twice.
  4. Whether each fact was a FIRST write to its (writer, tokenId, kind) row or a repeat
     is decided by replaying every `FactWritten` event from the deployment block in block
     and log order. The store charges a cold row and a warm row differently, so a
     per-fact gas figure that does not say which regime it is in is not comparable.
  5. Calldata gas is computed from the transaction's own bytes under EIP-2028
     (4 gas per zero byte, 16 per non-zero) and split into the call HEAD (selector,
     `writer`, array offset, array length) and the BODY (the 224-byte `FactInput`
     elements). That split is what makes the per-fact cost decomposable, because the head
     is paid once per transaction and the body once per fact.

Read-only. This makes `eth_getLogs`, `eth_getBlockByNumber`, `eth_getTransactionByHash`
and `eth_getTransactionReceipt` requests and sends no transaction. It needs no key beyond
an RPC URL and it never touches mainnet.

Usage
  SEPOLIA_RPC_URL=... python3 bench/oracle-gas-model/collect-shipped-writes.py \
      --to-block 11748000 > bench/oracle-gas-model/shipped-writes.json

`--to-block` is REQUIRED and is the reproducibility guarantee: the window is pinned to a
block that is already final, so re-running the same command against any Sepolia node
reproduces this file byte for byte -- there is deliberately no generated-at stamp in the
output, because one would break exactly that property. (`collect-chain-data.py`, by
contrast, reads a moving "now" by design.) A later refresh picks a later `--to-block` deliberately, and the new
window is recorded in the output.

Optionally pass --etherscan-cross-check to verify the transaction SET independently:
`eth_getLogs` cannot see a transaction that reverted, because a reverted transaction emits
no logs, so a log-derived list is a list of SUCCESSFUL calls. Etherscan's account txlist
includes failures, so the cross-check is what lets the page state that no batch reverted
rather than assume it. It needs ETHERSCAN_API_KEY and is recorded in the output either way.
"""
import argparse
import datetime
import json
import os
import sys
import time
import urllib.parse
import urllib.request

# The round-3 batched fact store and the block it was deployed in, from
# deployment-artifacts/ENG-4203-round3-fact-store.md. The from-block is not a flag: the
# first/repeat regime of every row is decided by replaying the store's WHOLE event history,
# so a window that starts later would mislabel a repeat write as a first write.
STORE = "0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D"
DEPLOYMENT_BLOCK = 11_704_139
# The contract-creation transaction. It emits no log, so it is invisible to eth_getLogs and is
# the ONE transaction Etherscan's txlist carries that the log-derived set legitimately does not.
# Naming it is what turns that difference from an unexplained mismatch into a checked one.
DEPLOYMENT_TX = "0xaa87473424dc72f92f076f6a87d48a88313b298fbcc10e69ae07043da519cad7"
CHAIN_ID = 11155111

# Function selectors and event topics of FabricaFactStore, from src/FabricaFactStore.sol.
# Each was produced by the command in the comment beside it, and each is CHECKED against the
# chain rather than trusted: every `writeFacts` transaction's decoded array length must equal
# its `FactWritten` log count, and any selector reaching this script that is not in this table
# is a hard error rather than an "other" bucket.
SELECTORS = {
    # cast sig 'writeFacts(address,(uint256,bytes32,uint128,uint24,uint64,uint64,bytes32)[])'
    "0x8712ac50": "writeFacts",
    # cast sig 'writeFact(address,(uint256,bytes32,uint128,uint24,uint64,uint64,bytes32))'
    "0x227d0124": "writeFact",
    # cast sig 'closeCycle(address,uint64)'
    "0x8b69e817": "closeCycle",
    # cast sig 'setLock(address,uint256,bool)'
    "0xa66bb09e": "setLock",
    # cast sig 'setMinValidCycle(address,uint64)'
    "0xeb1dd06e": "setMinValidCycle",
    # cast sig 'declarePolicy(uint16,uint16,uint64,bool)'
    "0xb9e11edf": "declarePolicy",
}
# cast keccak 'FactWritten(address,uint256,bytes32,uint128,uint24,uint64,uint64,bytes32)'
TOPIC_FACT_WRITTEN = "0x3e2fc348577610decc713fae096858bfe5d83e8a18baf79e9011a07182c69d9c"
# cast keccak 'CycleClosed(address,uint64,uint64)'
TOPIC_CYCLE_CLOSED = "0x2d01338bb60e0a30d4c31f360e128f5870124dd079df2f2be62c52c715f301d2"
# cast keccak 'LockSet(address,uint256,bool)'
TOPIC_LOCK_SET = "0x0f51c6ab7cf0d819916a7cbc8df8d491b8ceef0ebfb706ef0b5d4b60d9320a5f"

# The four configured oracle-source signers, by the address prefixes recorded on ENG-4204
# (the first scheduled-pass record, 2026-09-19). A prefix is resolved against the senders
# actually observed and must match EXACTLY ONE of them, so a label is a lookup that fails
# loudly rather than a guess. Any sender that matches no prefix keeps its address and is
# marked as not a keeper signer — the ENG-4203 deployment-verification writers are two such,
# and their rows must never be counted as shipped keeper traffic.
KEEPER_SIGNER_PREFIXES = {
    "0xfa2c254f": "prycd",
    "0x24e52f31": "regrid",
    "0x70ed67c1": "openAvm",
    "0x6a474020": "fabrica",
}

# Two transactions belong to the same keeper PASS if their block timestamps are within this
# many seconds of each other. The keeper cron is `0 */6`, so real passes are six hours apart
# and each settles inside a minute; the widest gap inside any observed pass is 4m 12s and the
# narrowest gap between passes is just under 6h. Any threshold in that range gives the same
# grouping, and the script asserts that it does by reporting the two figures.
PASS_GAP_SECONDS = 900

# EIP-2028 calldata pricing, and the EIP-7623 floor that Prague added. The floor is computed
# and reported so the page can state that it does not bind on any of these transactions
# rather than ignore it: `max(21000 + calldata + execution, 21000 + 10 * tokens)`.
GAS_ZERO_BYTE = 4
GAS_NONZERO_BYTE = 16
GAS_TX_BASE = 21_000
EIP7623_FLOOR_PER_TOKEN = 10
# A `FactInput` is seven 32-byte words and has no dynamic member, so array elements sit
# inline in calldata at a fixed stride.
FACT_INPUT_WORDS = 7
FACT_INPUT_BYTES = FACT_INPUT_WORDS * 32
# selector + `writer` word + array offset word + array length word.
WRITE_FACTS_HEAD_BYTES = 4 + 32 + 32 + 32

_id = [0]


def rpc(url, method, params):
    _id[0] += 1
    body = json.dumps({"jsonrpc": "2.0", "id": _id[0], "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                out = json.load(r)
            if "error" in out:
                raise RuntimeError(out["error"])
            return out["result"]
        except Exception:
            if attempt == 4:
                raise
            time.sleep(1.5 * (attempt + 1))


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def calldata_gas(data_hex, head_bytes=None):
    """Split a transaction's calldata into head and body and price both under EIP-2028.

    The head is paid once per transaction and the body once per fact, which is the whole
    reason the per-fact cost falls with batch size. Pricing the two together would hide it.
    `head_bytes` is supplied only for `writeFacts`, whose body is the FactInput array; for
    every other entry point the whole calldata is head and the body is empty, because there
    is no per-fact part to separate out.
    """
    raw = bytes.fromhex(data_hex[2:])
    split = len(raw) if head_bytes is None else head_bytes
    head = raw[:split]
    body = raw[split:]

    def price(chunk):
        zeros = sum(1 for b in chunk if b == 0)
        nonzeros = len(chunk) - zeros
        return {
            "bytes": len(chunk), "zeroBytes": zeros, "nonZeroBytes": nonzeros,
            "gas": GAS_ZERO_BYTE * zeros + GAS_NONZERO_BYTE * nonzeros,
            # EIP-7623 "tokens": one per zero byte, four per non-zero byte.
            "tokens": zeros + 4 * nonzeros,
        }

    whole, h, b = price(raw), price(head), price(body)
    return {
        "bytes": whole["bytes"], "zeroBytes": whole["zeroBytes"],
        "nonZeroBytes": whole["nonZeroBytes"], "gas": whole["gas"],
        "headBytes": h["bytes"], "headGas": h["gas"],
        "bodyBytes": b["bytes"], "bodyGas": b["gas"],
        "eip7623FloorGas": GAS_TX_BASE + EIP7623_FLOOR_PER_TOKEN * whole["tokens"],
    }


def decode_write_facts(data_hex, tx_hash):
    """Decode `writeFacts(address,FactInput[])` calldata into its writer and its facts."""
    raw = bytes.fromhex(data_hex[2:])
    body = raw[4:]
    writer = "0x" + body[12:32].hex()
    offset = int.from_bytes(body[32:64], "big")
    if offset != 64:
        sys.exit("%s: unexpected array offset %d in writeFacts calldata" % (tx_hash, offset))
    count = int.from_bytes(body[offset:offset + 32], "big")
    expected = offset + 32 + count * FACT_INPUT_BYTES
    if len(body) != expected:
        sys.exit("%s: writeFacts calldata is %d bytes after the selector, expected %d for %d facts"
                 % (tx_hash, len(body), expected, count))
    facts = []
    pos = offset + 32
    for _ in range(count):
        words = [body[pos + i * 32: pos + (i + 1) * 32] for i in range(FACT_INPUT_WORDS)]
        facts.append({
            "tokenId": str(int.from_bytes(words[0], "big")),
            "kind": "0x" + words[1].hex(),
            # `value` is a uint128 on chain. It is carried as a STRING, never a float:
            # a price in this system is an integer a JSON number cannot always hold.
            "value": str(int.from_bytes(words[2], "big")),
            "confidence": int.from_bytes(words[3], "big"),
            "valuedAt": int.from_bytes(words[4], "big"),
            "cycle": int.from_bytes(words[5], "big"),
            "data": "0x" + words[6].hex(),
        })
        pos += FACT_INPUT_BYTES
    return writer, facts


def decode_close_cycle(data_hex):
    body = bytes.fromhex(data_hex[2:])[4:]
    return "0x" + body[12:32].hex(), int.from_bytes(body[32:64], "big")


def decode_set_lock(data_hex):
    body = bytes.fromhex(data_hex[2:])[4:]
    return ("0x" + body[12:32].hex(), str(int.from_bytes(body[32:64], "big")),
            int.from_bytes(body[64:96], "big") == 1)


def label_signers(senders):
    """Resolve the ENG-4204 signer prefixes against the senders actually seen on chain."""
    labels = {}
    for prefix, name in KEEPER_SIGNER_PREFIXES.items():
        hits = [s for s in senders if s.lower().startswith(prefix)]
        if len(hits) > 1:
            sys.exit("signer prefix %s matches %d observed senders: %s" % (prefix, len(hits), hits))
        if hits:
            labels[hits[0].lower()] = name
    return labels


def etherscan_cross_check(api_key, from_block, to_block):
    """Independently list the store's transactions, failures included, via Etherscan V2."""
    url = "https://api.etherscan.io/v2/api?" + urllib.parse.urlencode({
        "chainid": CHAIN_ID, "module": "account", "action": "txlist", "address": STORE,
        "startblock": from_block, "endblock": to_block, "sort": "asc", "apikey": api_key,
    })
    with urllib.request.urlopen(url, timeout=60) as r:
        payload = json.load(r)
    if payload.get("status") != "1":
        return {"ran": True, "ok": False, "message": str(payload.get("message") or payload.get("result"))}
    rows = payload["result"]
    return {
        "ran": True, "ok": True,
        "endpoint": "https://api.etherscan.io/v2/api module=account action=txlist chainid=%d" % CHAIN_ID,
        "transactions": len(rows),
        "failed": [r["hash"] for r in rows if r.get("isError") == "1"],
        "hashes": sorted(r["hash"].lower() for r in rows),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--to-block", type=int, required=True,
                    help="last block of the pinned window; must already be final")
    ap.add_argument("--etherscan-cross-check", action="store_true",
                    help="also list the store's transactions via Etherscan, failures included")
    args = ap.parse_args()

    url = os.environ["SEPOLIA_RPC_URL"]
    chain_id = int(rpc(url, "eth_chainId", []), 16)
    if chain_id != CHAIN_ID:
        sys.exit("SEPOLIA_RPC_URL points at chain %d, expected Sepolia (%d)" % (chain_id, CHAIN_ID))
    head = int(rpc(url, "eth_blockNumber", []), 16)
    if args.to_block > head:
        sys.exit("--to-block %d is ahead of the chain head %d" % (args.to_block, head))
    if args.to_block < DEPLOYMENT_BLOCK:
        sys.exit("--to-block %d is before the store's deployment block %d"
                 % (args.to_block, DEPLOYMENT_BLOCK))

    logs = rpc(url, "eth_getLogs", [{"address": STORE, "fromBlock": hex(DEPLOYMENT_BLOCK),
                                     "toBlock": hex(args.to_block)}])
    # Order of first appearance is (block, transaction index): the chain's own order, not the
    # order the node happened to return.
    position = {}
    for log in logs:
        position.setdefault(log["transactionHash"].lower(),
                            (int(log["blockNumber"], 16), int(log["transactionIndex"], 16)))
    hashes = sorted(position, key=lambda h: position[h])

    blocks = {}

    def block_time(number):
        if number not in blocks:
            blocks[number] = int(rpc(url, "eth_getBlockByNumber", [hex(number), False])["timestamp"], 16)
        return blocks[number]

    # First/repeat regime per (writer, tokenId, kind), replayed in chain order over the whole
    # history. `seen` is the count BEFORE the transaction being decoded.
    seen = {}
    transactions = []
    for tx_hash in hashes:
        tx = rpc(url, "eth_getTransactionByHash", [tx_hash])
        receipt = rpc(url, "eth_getTransactionReceipt", [tx_hash])
        selector = tx["input"][:10]
        if selector not in SELECTORS:
            sys.exit("%s calls unknown selector %s on the store; refusing to classify it as "
                     "'other'" % (tx_hash, selector))
        op = SELECTORS[selector]
        status = int(receipt["status"], 16)
        gas_used = int(receipt["gasUsed"], 16)
        gas_price_wei = int(receipt["effectiveGasPrice"], 16)
        number = int(tx["blockNumber"], 16)
        store_logs = [l for l in receipt["logs"] if l["address"].lower() == STORE.lower()]
        row = {
            "hash": tx_hash,
            "block": number,
            "timeUtc": iso(block_time(number)),
            "timestamp": block_time(number),
            "from": tx["from"].lower(),
            "nonce": int(tx["nonce"], 16),
            "op": op,
            "status": status,
            "gasUsed": gas_used,
            # Wei figures are STRINGS. A fee in wei can exceed what a double holds exactly,
            # and the page multiplies them; carrying them as JSON numbers would round.
            "effectiveGasPriceWei": str(gas_price_wei),
            "feeWei": str(gas_used * gas_price_wei),
            "calldata": calldata_gas(tx["input"],
                                     WRITE_FACTS_HEAD_BYTES if op == "writeFacts" else None),
            "logs": len(store_logs),
        }
        if op == "writeFacts" or op == "writeFact":
            if op == "writeFacts":
                writer, facts = decode_write_facts(tx["input"], tx_hash)
            else:
                raw = bytes.fromhex(tx["input"][2:])[4:]
                writer = "0x" + raw[12:32].hex()
                words = [raw[32 + i * 32: 64 + i * 32] for i in range(FACT_INPUT_WORDS)]
                facts = [{
                    "tokenId": str(int.from_bytes(words[0], "big")), "kind": "0x" + words[1].hex(),
                    "value": str(int.from_bytes(words[2], "big")),
                    "confidence": int.from_bytes(words[3], "big"),
                    "valuedAt": int.from_bytes(words[4], "big"),
                    "cycle": int.from_bytes(words[5], "big"), "data": "0x" + words[6].hex(),
                }]
            emitted = sum(1 for l in store_logs if l["topics"][0].lower() == TOPIC_FACT_WRITTEN)
            if emitted != len(facts):
                sys.exit("%s: calldata carries %d facts but the receipt has %d FactWritten logs"
                         % (tx_hash, len(facts), emitted))
            if writer.lower() != tx["from"].lower():
                sys.exit("%s: writer %s is not the sender %s" % (tx_hash, writer, tx["from"]))
            first = 0
            for fact in facts:
                key = (writer.lower(), fact["tokenId"], fact["kind"])
                if key not in seen:
                    seen[key] = 0
                    first += 1
                seen[key] += 1
            cycles = sorted({f["cycle"] for f in facts})
            kinds = sorted({f["kind"] for f in facts})
            non_zero_data = sum(1 for f in facts if int(f["data"], 16) != 0)
            row.update({
                "writer": writer.lower(), "facts": len(facts),
                "firstWrites": first, "repeatWrites": len(facts) - first,
                "factsWithNonZeroData": non_zero_data,
                "cycles": cycles, "kinds": kinds,
                # Floor division, the same rounding the keeper's own `gasPerFact` log uses.
                "gasPerFact": gas_used // len(facts),
                "execGas": gas_used - GAS_TX_BASE - row["calldata"]["gas"],
            })
        elif op == "closeCycle":
            writer, cycle = decode_close_cycle(tx["input"])
            row.update({"writer": writer.lower(), "cycle": cycle})
        elif op == "setLock":
            writer, token_id, value = decode_set_lock(tx["input"])
            row.update({"writer": writer.lower(), "tokenId": token_id, "locked": value})
        transactions.append(row)

    signers = label_signers({t["from"] for t in transactions})
    for row in transactions:
        row["signer"] = signers.get(row["from"])
        row["keeperSigner"] = row["from"] in signers

    # Group into passes by a gap in block timestamps, and report the two gaps that justify the
    # threshold so it can be checked rather than believed.
    passes, current = [], []
    widest_inside, narrowest_between = 0, None
    for row in transactions:
        if current and row["timestamp"] - current[-1]["timestamp"] > PASS_GAP_SECONDS:
            gap = row["timestamp"] - current[-1]["timestamp"]
            narrowest_between = gap if narrowest_between is None else min(narrowest_between, gap)
            passes.append(current)
            current = []
        elif current:
            widest_inside = max(widest_inside, row["timestamp"] - current[-1]["timestamp"])
        current.append(row)
    if current:
        passes.append(current)

    def summarise(group):
        writes = [r for r in group if r["op"] in ("writeFacts", "writeFact")]
        locks = [r for r in group if r["op"] == "setLock"]
        closes = [r for r in group if r["op"] == "closeCycle"]
        cycles = sorted({c for r in writes for c in r["cycles"]} | {r["cycle"] for r in closes})
        by_signer = {}
        for r in group:
            key = r["signer"] or r["from"]
            slot = by_signer.setdefault(key, {"transactions": 0, "facts": 0, "gasUsed": 0,
                                              "feeWei": 0, "keeperSigner": r["keeperSigner"]})
            slot["transactions"] += 1
            slot["facts"] += r.get("facts", 0)
            slot["gasUsed"] += r["gasUsed"]
            slot["feeWei"] += int(r["feeWei"])
        for slot in by_signer.values():
            slot["feeWei"] = str(slot["feeWei"])
        return {
            "startTimeUtc": group[0]["timeUtc"], "endTimeUtc": group[-1]["timeUtc"],
            "fromBlock": group[0]["block"], "toBlock": group[-1]["block"],
            "transactions": len(group),
            "writeTransactions": len(writes), "lockTransactions": len(locks),
            "closeTransactions": len(closes),
            "facts": sum(r.get("facts", 0) for r in writes),
            "largestBatch": max([r["facts"] for r in writes], default=0),
            "cycles": cycles,
            "gasUsed": sum(r["gasUsed"] for r in group),
            "feeWei": str(sum(int(r["feeWei"]) for r in group)),
            "keeperPass": all(r["keeperSigner"] for r in group),
            "signers": by_signer,
            "hashes": [r["hash"] for r in group],
        }

    pass_rows = [summarise(g) for g in passes]

    cross = {"ran": False}
    if args.etherscan_cross_check:
        key = os.environ.get("ETHERSCAN_API_KEY")
        if not key:
            sys.exit("--etherscan-cross-check needs ETHERSCAN_API_KEY")
        cross = etherscan_cross_check(key, DEPLOYMENT_BLOCK, args.to_block)
        if cross.get("ok"):
            mine = set(t["hash"] for t in transactions)
            extra = [h for h in cross["hashes"] if h not in mine]
            cross["onlyInEtherscan"] = extra
            cross["onlyInLogs"] = sorted(h for h in mine if h not in set(cross["hashes"]))
            # The creation transaction is expected to be the only one Etherscan adds.
            cross["onlyInEtherscanIsTheDeployment"] = extra == [DEPLOYMENT_TX]
            cross["matchesLogDerivedSet"] = (
                not cross["onlyInLogs"] and cross["onlyInEtherscanIsTheDeployment"])
            cross["explanation"] = (
                "Etherscan lists the contract-creation transaction, which emits no log and so "
                "cannot appear in an eth_getLogs result. Apart from it the two lists are "
                "identical, and `failed` is the list of reverted calls."
                if cross["matchesLogDerivedSet"] else
                "The two lists differ by more than the contract-creation transaction.")
            del cross["hashes"]

    out = {
        # Deliberately NO generated-at timestamp. The window below is pinned to a final block,
        # so this file is a pure function of (store, window) and re-running the command
        # reproduces it byte for byte -- which a wall-clock stamp would quietly break, and
        # which is the property the page's input digest rests on. When it was collected is
        # recorded by the commit that carries it.
        "chain": {"name": "sepolia", "chainId": CHAIN_ID},
        "store": STORE,
        "storeSource": "deployment-artifacts/ENG-4203-round3-fact-store.md",
        # The protocol constants every figure here is decomposed with, carried out rather than
        # left for the page to hard-code: a gas schedule is an input, and an input belongs in
        # the data the digest covers.
        "gasConstants": {
            "txBase": GAS_TX_BASE,
            "calldataZeroByte": GAS_ZERO_BYTE,
            "calldataNonZeroByte": GAS_NONZERO_BYTE,
            "eip7623FloorPerToken": EIP7623_FLOOR_PER_TOKEN,
            "source": "EIP-2028 calldata pricing and the EIP-7623 floor; the intrinsic base is "
                      "the yellow-paper G_transaction",
        },
        "window": {
            "fromBlock": DEPLOYMENT_BLOCK, "toBlock": args.to_block,
            "fromTimeUtc": iso(block_time(DEPLOYMENT_BLOCK)),
            "toTimeUtc": iso(block_time(args.to_block)),
        },
        "collection": {
            "command": "SEPOLIA_RPC_URL=... python3 bench/oracle-gas-model/collect-shipped-writes.py"
                       " --to-block %d --etherscan-cross-check"
                       " > bench/oracle-gas-model/shipped-writes.json" % args.to_block,
            "method": "eth_getLogs over the store for the whole window, then "
                      "eth_getTransactionByHash + eth_getTransactionReceipt per transaction; "
                      "fact counts decoded from writeFacts calldata AND counted from the "
                      "FactWritten logs, which must agree; first-versus-repeat row regime "
                      "replayed from the store's whole event history; calldata gas computed "
                      "from the transaction's own bytes under EIP-2028",
            "reproducibility": "the window is pinned to a final block, so re-running this exact "
                               "command against any Sepolia node reproduces this file",
            "selectorsVerifiedBy": "cast sig / cast keccak, the commands in the SELECTORS table "
                                   "of this script; each is also checked against the chain, "
                                   "since every writeFacts array length must equal its "
                                   "FactWritten log count",
        },
        "passGrouping": {
            "gapSeconds": PASS_GAP_SECONDS,
            "widestGapInsideAPass": widest_inside,
            "narrowestGapBetweenPasses": narrowest_between,
            "rule": "a gap in block timestamps larger than gapSeconds starts a new pass; any "
                    "threshold between widestGapInsideAPass and narrowestGapBetweenPasses "
                    "gives this same grouping",
        },
        "signers": {addr: name for addr, name in signers.items()},
        "signerSource": "address prefixes recorded on ENG-4204 (first scheduled-pass record, "
                        "2026-09-19), resolved against the senders observed on chain",
        "keeperConfig": {
            "maxTransactionsPerCycle": 20,
            "writeBatchSize": 25,
            "maxTokensPerCycle": 25,
            "cronSchedule": "0 */6 * * *",
            # The aggregator's trusted price set. `fabrica` is deliberately NOT in it: it stamps
            # token-wide score and attribute facts, not source prices (ENG-4204, NOTE 2 closure).
            "priceWriters": ["prycd", "regrid", "openAvm"],
            "source": "ENG-4204 / fabrica-v3-api#1903",
            "note": "These are keeper CONFIGURATION values, not chain reads. Only the "
                    "transaction ceiling is corroborated by the chain, by passes that stop on "
                    "it exactly.",
        },
        "easWritePath": {
            "exists": False,
            # Split in two so a page can lead with the headline and follow with the evidence
            # without repeating itself.
            "headline": "No EAS write path exists in the keeper.",
            "surface": "The keeper's entire on-chain write surface is writeFact, writeFacts, "
                       "closeCycle, setLock and setMinValidCycle on FabricaFactStore.",
            "checkedAt": "fabrica-v3-api src/onchain-oracle-keeper/, HEAD 5a35f674; "
                         "fabrica-fact-store.abi.ts is the only store ABI and carries no "
                         "attestation entry point; `git grep -niE 'attest|multiAttest|"
                         "schemaRegistry|\\bEAS\\b' -- src/onchain-oracle-keeper` returns nothing",
        },
        "etherscanCrossCheck": cross,
        "passes": pass_rows,
        "transactions": transactions,
    }
    json.dump(out, sys.stdout, indent=1)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
