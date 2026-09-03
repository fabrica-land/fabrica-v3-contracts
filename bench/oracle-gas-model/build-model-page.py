#!/usr/bin/env python3
"""ENG-3913: generate index.html from the literal measurement artifacts.

The page is generated, never hand-edited, so that every number on it is traceable to a
file in this directory and a reviewer can regenerate it and diff rather than trust it.

Inputs
  reports/bench-rows.txt        literal `forge test -vv` output (per-scenario gas)
  reports/deployed-vs-main.txt  literal output of the deployed-vs-main comparison
  chain-data.json               mainnet figures, produced by collect-chain-data.py

Usage:  python3 build-model-page.py            # writes index.html next to this script
"""
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]


def parse_bench_rows(path):
    """Rows are `ENG3913ROW,<name>,call,overhead,exec,cdBytes,cdGas,txTotal`.

    The name may itself contain commas, so the six numeric fields are taken from the end.
    """
    out = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if "ENG3913ROW," not in line:
            continue
        parts = line[line.index("ENG3913ROW,") + len("ENG3913ROW,"):].split(",")
        nums = [int(p) for p in parts[-6:]]
        name = ",".join(parts[:-6]).strip()
        out[name] = dict(zip(
            ["callGas", "overheadGas", "execGas", "calldataBytes", "calldataGas", "txTotal"], nums))
    return out


def parse_compare(path):
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if "ENG3913CMP," not in line:
            continue
        body = line[line.index("ENG3913CMP,") + len("ENG3913CMP,"):]
        fields = body.split(",")
        name = fields[0]
        kv = {}
        for f in fields[1:]:
            if "=" in f:
                k, v = f.split("=", 1)
                kv[k] = v
        out.append({"scenario": name, **kv})
    return out


def git(*args):
    return subprocess.check_output(["git", "-C", str(REPO), *args], text=True).strip()


def main():
    rows = parse_bench_rows(HERE / "reports" / "bench-rows.txt")
    compare = parse_compare(HERE / "reports" / "deployed-vs-main.txt")
    chain = json.loads((HERE / "chain-data.json").read_text())
    required = [
        "register:first under validator", "register:subsequent",
        "registerBatch:1", "registerBatch:10", "registerBatch:100", "registerBatch:1000",
        "writePrice:first", "writePrice:second (ring slot cold)",
        "writePrice:writes 3-48 (ring slot fresh, counter warm)",
        "writePrice:write 49+ (ring wrapped), price moved",
        "writePrice:write 49+ (ring wrapped), price unchanged",
        "writePriceRelayed:first", "writePriceRelayed:second (ring slot cold)",
        "writePriceRelayed:writes 3-48 (ring slot fresh, counter warm)",
        "writePriceRelayed:write 49+ (ring wrapped), price moved",
        "writeAttribute:first", "writeAttribute:repeat, value changed",
        "writeAttribute:repeat, value unchanged",
        "heartbeat:first", "heartbeat:repeat",
    ]
    missing = [r for r in required if r not in rows]
    if missing:
        # Fail loudly. A page that silently drops a scenario is worse than no page.
        sys.exit("missing measured scenarios, refusing to build a page with holes:\n  "
                 + "\n  ".join(missing))

    meta = {
        "commit": git("rev-parse", "HEAD"),
        "commitShort": git("rev-parse", "--short", "HEAD"),
        "branch": git("rev-parse", "--abbrev-ref", "HEAD"),
        "historyDepth": 48,
        "reportHeader": (HERE / "reports" / "bench-rows.txt").read_text().split("\n\n")[0],
    }

    payload = json.dumps(
        {"rows": rows, "compare": compare, "chain": chain, "meta": meta},
        indent=1, sort_keys=True)
    html = (HERE / "page-template.html").read_text().replace("/*__DATA__*/null", payload)
    (HERE / "index.html").write_text(html)
    print("wrote", HERE / "index.html", f"({len(html):,} bytes, {len(rows)} measured scenarios)")


if __name__ == "__main__":
    main()
