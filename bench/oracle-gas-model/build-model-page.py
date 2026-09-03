#!/usr/bin/env python3
"""ENG-3913: generate index.html from the literal measurement artifacts.

The page is generated, never hand-edited, so that every number on it is traceable to a
file in this directory and a reviewer can regenerate it and diff rather than trust it.

Inputs
  reports/bench-rows.txt        literal `forge test -vv` output (per-scenario gas)
  reports/deployed-vs-main.txt  literal output of the deployed-vs-main comparison
  chain-data.json               mainnet figures, produced by collect-chain-data.py

Usage:  python3 build-model-page.py            # writes index.html next to this script
        python3 build-model-page.py --check    # verify index.html matches its inputs; no write

`--check` is the reproducibility guarantee and needs no RPC and no keys. It is what a
reviewer should run: a commit SHA cannot be stamped into a file that lives inside that same
commit, but "this page is exactly what its committed inputs produce" is checkable, and that
is the property that actually matters.
"""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[1]


FIELDS = ["callGas", "overheadGas", "execGas", "calldataBytes", "calldataGas", "txTotal"]


def parse_bench_rows(path):
    """Rows are `ENG3913ROW,<name>,call,overhead,exec,cdBytes,cdGas,txTotal`.

    Scenario names contain commas ("...ring wrapped), price moved"), so the six numeric
    fields are taken from the END and everything before them is the name.

    A malformed row is a hard error, never a silently truncated one: `zip` would happily
    pair four numbers with six field names and produce a row with missing keys, which would
    then surface as `undefined` somewhere in the page rather than as a build failure.
    """
    out = {}
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if "ENG3913ROW," not in line:
            continue
        parts = line[line.index("ENG3913ROW,") + len("ENG3913ROW,"):].split(",")
        if len(parts) < len(FIELDS) + 1:
            sys.exit("%s:%d: row has %d fields, need at least %d:\n  %s"
                     % (path, lineno, len(parts), len(FIELDS) + 1, line))
        tail = parts[-len(FIELDS):]
        try:
            nums = [int(t.strip()) for t in tail]
        except ValueError:
            sys.exit("%s:%d: last %d fields are not all integers:\n  %s"
                     % (path, lineno, len(FIELDS), line))
        name = ",".join(parts[:-len(FIELDS)]).strip()
        if not name:
            sys.exit("%s:%d: row has an empty scenario name:\n  %s" % (path, lineno, line))
        if name in out:
            sys.exit("%s:%d: duplicate scenario %r" % (path, lineno, name))
        out[name] = dict(zip(FIELDS, nums))
    return out


def parse_compare(path):
    """Rows are `ENG3913CMP,<name>,k=v,k=v,...`.

    The scenario name contains commas, so the name is everything before the FIRST field
    that looks like `key=value`, not just the first comma-separated token. Splitting on the
    first comma truncated "writePrice:second (ring slot cold)" to "writePrice:second (ring
    slot cold)" losing nothing visible, but truncated the wrapped-ring names mid-phrase.
    """
    out = []
    for lineno, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if "ENG3913CMP," not in line:
            continue
        body = line[line.index("ENG3913CMP,") + len("ENG3913CMP,"):]
        fields = body.split(",")
        first_kv = next((i for i, f in enumerate(fields) if "=" in f), None)
        if first_kv is None or first_kv == 0:
            sys.exit("%s:%d: cannot separate scenario name from key=value fields:\n  %s"
                     % (path, lineno, line))
        name = ",".join(fields[:first_kv]).strip()
        kv = {}
        for f in fields[first_kv:]:
            if "=" not in f:
                sys.exit("%s:%d: trailing field %r is not key=value:\n  %s" % (path, lineno, f, line))
            k, v = f.split("=", 1)
            kv[k.strip()] = v.strip()
        out.append({"scenario": name, **kv})
    if not out:
        sys.exit("%s: no ENG3913CMP rows found" % path)
    return out


PLACEHOLDER = "/*__DATA__*/null"
# Everything the page is built from. The digest over these is a provenance stamp that, unlike
# a commit SHA, a committed file CAN name: it does not change when the file is committed.
INPUTS = [
    "page-template.html",
    "chain-data.json",
    "reports/bench-rows.txt",
    "reports/deployed-vs-main.txt",
    "reports/gas-report.txt",
]


def git(*args):
    return subprocess.check_output(["git", "-C", str(REPO), *args], text=True).strip()


# The provenance fields, excluded from the --check comparison. See the note in main().
#
# `branch` used to be injected here too and is deliberately gone: it is not provenance the
# guarantee rests on (the input digest is), and comparing it made --check fail on `main`,
# on any detached checkout, and in CI -- i.e. everywhere except the one branch that merging
# deletes. A check that is red wherever the page actually lives is worse than no check.
META_FIELDS = ("commit", "commitShort")


def normalise(text):
    """Blank the git-meta values so two builds of the same inputs compare equal."""
    for field in META_FIELDS:
        text = re.sub(r'("%s": ")[^"]*(")' % field, r"\1<meta>\2", text)
    return text


def input_digest():
    h = hashlib.sha256()
    for name in INPUTS:
        h.update(name.encode())
        h.update(b"\0")
        h.update((HERE / name).read_bytes())
        h.update(b"\0")
    return h.hexdigest()[:16]


def main():
    check_only = "--check" in sys.argv[1:]
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
        "historyDepth": 48,
        "reportHeader": (HERE / "reports" / "bench-rows.txt").read_text().split("\n\n")[0],
    }

    meta["inputDigest"] = input_digest()

    payload = json.dumps(
        {"rows": rows, "compare": compare, "chain": chain, "meta": meta},
        indent=1, sort_keys=True)
    # The payload is embedded inside a <script> block, so two sequences must not survive
    # verbatim: `</script` would end the block early, and a bare `&` is ambiguous to an HTML
    # parser in some contexts. Both have JSON escapes that parse back to the same string, so
    # escaping them changes nothing about the data. reportHeader carries free text from the
    # report files and is the realistic source of either.
    payload = (payload.replace("&", "\\u0026")
                      .replace("<", "\\u003c")
                      .replace(">", "\\u003e")
                      .replace("\u2028", "\\u2028")
                      .replace("\u2029", "\\u2029"))

    template = (HERE / "page-template.html").read_text()
    if PLACEHOLDER not in template:
        sys.exit("page-template.html no longer contains the %r placeholder; refusing to write a "
                 "page with no data in it" % PLACEHOLDER)
    html = template.replace(PLACEHOLDER, payload)
    if PLACEHOLDER in html:
        sys.exit("placeholder survived substitution; refusing to write")

    target = HERE / "index.html"
    if check_only:
        if not target.exists():
            sys.exit("--check: index.html does not exist")
        current = target.read_text()
        # The git-meta fields record the commit the page was BUILT from, which is necessarily
        # the parent of the commit that carries the page -- committing the page changes HEAD.
        # So they differ on every head after the one that built it, and comparing them would
        # make --check fail for every reviewer on every commit. They are provenance, not
        # content. The content identity is `inputDigest`, which hashes the inputs and not the
        # repository, and that IS compared.
        if normalise(current) == normalise(html):
            print("--check: index.html is exactly what its committed inputs produce "
                  f"({len(html):,} bytes, {len(rows)} measured scenarios)")
            print("         input digest %s" % meta["inputDigest"])
            cur_commit = re.search(r'"commitShort": "([^"]*)"', current)
            if cur_commit and cur_commit.group(1) != meta["commitShort"]:
                print("         (built from %s; HEAD is now %s — expected, and not compared: a "
                      "committed\n          page cannot name its own commit)"
                      % (cur_commit.group(1), meta["commitShort"]))
            return
        # Say WHERE it differs; "they differ" is not actionable. Diff the normalised text so
        # the git-meta lines never appear as noise ahead of the real difference.
        import difflib
        diff = list(difflib.unified_diff(normalise(current).splitlines(),
                                         normalise(html).splitlines(),
                                         "committed index.html", "regenerated", lineterm="", n=1))
        sys.exit("--check FAILED: index.html does not match its inputs (%d diff lines)\n%s"
                 % (len(diff), "\n".join(diff[:40])))

    target.write_text(html)
    print("wrote", target, f"({len(html):,} bytes, {len(rows)} measured scenarios)")


if __name__ == "__main__":
    main()
