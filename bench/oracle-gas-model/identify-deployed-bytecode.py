#!/usr/bin/env python3
"""ENG-3913 / F8: identify which commit's source produced the deployed round-1 fact store.

The page claims the deployed Sepolia fact store is commit 062f049 and that every byte of
difference from a local build lies in an immutable slot. That claim needs an artifact, not a
recollection, so this script produces one.

Method: fetch the deployed runtime bytecode with eth_getCode, build each candidate commit's
source, strip the trailing CBOR metadata from both (it encodes compiler and source hashes and
differs for reasons that are not logic), and compare byte by byte. Every differing offset is
then checked against the build artifact's `immutableReferences`, which lists exactly where
the compiler placed constructor-set immutables -- those bytes are zero in the artifact and
carry the deployed values on chain, so they SHOULD differ and their differing is not evidence
of a code difference.

Usage:  SEPOLIA_RPC_URL=... python3 identify-deployed-bytecode.py > reports/deployed-bytecode-id.txt

Read-only: one eth_getCode call, no transaction.
"""
import json
import os
import subprocess
import sys
import urllib.request

ADDRESS = "0xFfA7535eF090C9193f44399843a05b60808ffC0D"  # round-1 fact store, Sepolia
CANDIDATES = ["062f049", "23f200f", "10aafd6"]
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))


def rpc(method, params):
    req = urllib.request.Request(
        os.environ["SEPOLIA_RPC_URL"],
        data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def strip_metadata(hexstr):
    """Drop the trailing CBOR metadata blob, whose length is its last two bytes."""
    h = hexstr[2:] if hexstr.startswith("0x") else hexstr
    return h[:-(int(h[-4:], 16) * 2 + 4)]


def git(*args):
    return subprocess.check_output(["git", "-C", REPO, *args], text=True)


def main():
    live = strip_metadata(rpc("eth_getCode", [ADDRESS, "latest"]).lower())
    print("deployed round-1 fact store : %s (Sepolia)" % ADDRESS)
    print("runtime bytes, metadata stripped : %d" % (len(live) // 2))
    print()

    for commit in CANDIDATES:
        src = git("show", "%s:src/FabricaAttributeOracle.sol" % commit)
        tmp_dir = os.path.join(REPO, "src", "eng3913-bytecode-id")
        os.makedirs(tmp_dir, exist_ok=True)
        name = "Candidate_%s" % commit
        path = os.path.join(tmp_dir, "%s.sol" % name)
        with open(path, "w") as f:
            f.write(src.replace("contract FabricaAttributeOracle is", "contract %s is" % name, 1))
        try:
            subprocess.run(["forge", "build"], cwd=REPO, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            artifact = os.path.join(REPO, "out", "%s.sol" % name, "%s.json" % name)
            with open(artifact) as f:
                art = json.load(f)
        finally:
            os.remove(path)
            try:
                os.rmdir(tmp_dir)
            except OSError:
                pass

        built = strip_metadata(art["deployedBytecode"]["object"].lower())
        # Offsets the compiler reserved for constructor-set immutables.
        immutable = set()
        for slots in art["deployedBytecode"].get("immutableReferences", {}).values():
            for slot in slots:
                immutable.update(range(slot["start"], slot["start"] + slot["length"]))

        print("candidate %s" % commit)
        print("  built runtime bytes            : %d" % (len(built) // 2))
        if len(built) != len(live):
            print("  LENGTH MISMATCH -> not this commit")
            print()
            continue
        diffs = [i // 2 for i in range(0, len(live), 2) if live[i:i + 2] != built[i:i + 2]]
        outside = [d for d in diffs if d not in immutable]
        print("  differing bytes                : %d of %d" % (len(diffs), len(live) // 2))
        print("  of those, inside an immutable  : %d" % (len(diffs) - len(outside)))
        print("  of those, OUTSIDE an immutable : %d" % len(outside))
        if diffs and not outside:
            print("  VERDICT: MATCH. Every differing byte is in a slot the compiler reserved")
            print("           for a constructor-set immutable, so the logic is identical and")
            print("           only the deployed knob values differ.")
            sample = sorted(diffs)[:6]
            print("  sample   : " + ", ".join(
                "@%d live=%s built=%s" % (d, live[d * 2:d * 2 + 2], built[d * 2:d * 2 + 2])
                for d in sample))
        else:
            print("  VERDICT: NOT THIS COMMIT (%d bytes differ outside immutables, e.g. %s)"
                  % (len(outside), outside[:8]))
        print()


if __name__ == "__main__":
    main()
