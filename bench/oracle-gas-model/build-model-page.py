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
    # ENG-3938: the write-side batch measurements for both arms, vendored verbatim from
    # ENG-3922's committed arms report, plus the sidecar that pins the commit it came from.
    # In INPUTS so the digest changes when the report is swapped for its final revision.
    "reports/eng3922-arms.txt",
    "reports/eng3922-source.txt",
    # ENG-3944: the read side. The arms report already carried the per-arm price() rows; the
    # baseline report carries the deployed aggregator's read, and the Sepolia evidence carries
    # the four real-transaction probe receipts that corroborate the fork. All three are vendored
    # verbatim from the same merged commit, and all three are in INPUTS so the digest tracks them.
    "reports/eng3922-baseline.txt",
    "reports/eng3922-sepolia-evidence.md",
]

# ENG-3938: the batch-size dial drives the write-side per-item cost at these sizes. writePriceBatch
# (bespoke) and multiAttest (EAS) are measured only to 100; batching is converged well before it.
BATCH_SIZES = [1, 10, 100]


def count_measured_rows(path):
    """Count the measured `  label: <int>` lines in a forge report.

    The row count is the one figure the provenance sidecar states about the report it describes,
    and until ENG-3964 it was typed. It went stale within the hour: the count was taken after the
    first regeneration and three more benches were added afterwards, leaving the sidecar 54 rows
    light while still claiming to describe the committed file. Counting it here, and refusing when
    the sidecar disagrees, is the same treatment every other derived figure in this directory gets.
    """
    return sum(1 for line in path.read_text().splitlines()
               if re.match(r"\s{2}.+?: \d+$", line.rstrip()))


def assert_sidecar_row_counts(meta, arms_path, base_rows):
    """The sidecar's row accounting must match the report it ships beside.

    `armsRowsAfter` is checked against the committed report; `armsRowsMoved` is not recomputed here
    (it needs the base revision, which a committed file cannot reach) but IS asserted to be the
    zero it claims, so a future regeneration that moves a row cannot keep the claim silently.
    """
    actual = count_measured_rows(arms_path)
    claimed = meta.get("armsRowsAfter")
    if claimed is None:
        return
    if int(claimed) != actual:
        sys.exit("reports/eng3922-source.txt: armsRowsAfter says %s but %s holds %d measured rows. "
                 "The sidecar describes the report it ships with, so update it -- or, if rows were "
                 "added deliberately, re-run the row-by-row comparison against the base revision "
                 "before changing the number" % (claimed, arms_path.name, actual))
    before = meta.get("armsRowsBefore")
    if before is not None and int(before) != base_rows:
        sys.exit("reports/eng3922-source.txt: armsRowsBefore says %s but the vendored base is %d "
                 "rows" % (before, base_rows))


def parse_source(path):
    """Read reports/eng3922-source.txt: the provenance of the vendored ENG-3922 arms report.

    Lines are `key: value`; comment lines start with `#`. The commit and status travel onto the
    page so a reader sees exactly which report revision every batch number came from, and whether
    it is still provisional.
    """
    meta = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            sys.exit("%s: line is neither a comment nor key:value:\n  %s" % (path, line))
        k, v = line.split(":", 1)
        meta[k.strip()] = v.strip()
    for req in ("file", "commit", "status", "pr"):
        if req not in meta:
            sys.exit("%s: missing required provenance line %r" % (path, req))
    moved = meta.get("armsRowsMoved")
    if moved not in (None, "0") and not meta.get("armsRowsMovedReason", "").strip():
        sys.exit("%s: armsRowsMoved is %r with no armsRowsMovedReason. A moved row means a figure "
                 "this page renders has changed, so the provenance claim has to be REWRITTEN and "
                 "the reason stated -- not the number bumped" % (path, moved))
    return meta


def parse_arms_batch(path):
    """Extract whole-transaction gas for the batched write ops the dial needs, at n=1/10/100.

    Lines in the arms report look like:
      ownerless writePriceBatch n=10 -- WHOLE TRANSACTION: 794583
      ownerless writePriceBatch n=10 -- WHOLE TRANSACTION per item: 79458
      EAS multiAttest n=1 -- WHOLE TRANSACTION: 312052    (n=1 prints no per-item line)

    The WHOLE TRANSACTION figure is the authoritative measured number. Per item is floor(total/n),
    computed here rather than trusted from the report, and where the report DOES print a per-item
    line it is asserted equal to that floor -- so a report reformat cannot silently feed the page a
    number that no longer matches its own total. A missing row is a hard error: the dial needs it.
    """
    text = path.read_text()
    ops = {
        "ownerless writePriceBatch": "writePriceBatch",
        "EAS multiAttest": "multiAttest",
        "EAS indexAttestations": "indexAttestations",
        "EAS multiRevoke": "multiRevoke",
        "pointer pointBatch": "pointBatch",
    }
    out = {}
    for label, key in ops.items():
        sizes = {}
        for n in BATCH_SIZES:
            m = re.search(re.escape(label) + r" n=%d -- WHOLE TRANSACTION: (\d+)" % n, text)
            if not m:
                sys.exit("%s: missing measured row %r at n=%d -- the batch dial needs it"
                         % (path, label + " -- WHOLE TRANSACTION", n))
            total = int(m.group(1))
            per_item = total // n
            pm = re.search(re.escape(label) + r" n=%d -- WHOLE TRANSACTION per item: (\d+)" % n, text)
            if pm and int(pm.group(1)) != per_item:
                sys.exit("%s: %r n=%d per-item %s does not equal floor(total/n)=%d"
                         % (path, label, n, pm.group(1), per_item))
            sizes[str(n)] = {"total": total, "perItem": per_item}
        out[key] = sizes
    return out


# ENG-3944: the read side. The order is ascending measured gas and is the order every read-side
# table on the page renders in. `needle` is the literal prefix the arms report prints for that arm;
# `probe` is the literal row label the Sepolia evidence table uses for the same arm.
READ_ARMS = [
    {"key": "arm3", "label": "arm 3 — ownerless custom store", "short": "arm 3",
     "needle": "arm3 ownerless store", "probe": "arm 3 — ownerless custom store",
     "family": "store", "reference": True},
    {"key": "cal", "label": "calibration — deployed round-1 store, read through the harness",
     "short": "the calibration arm",
     "needle": "cal. round-1 store", "probe": None,
     "family": "store", "reference": True},
    {"key": "arm1C", "label": "arm 1C — all-EAS via `oracleContext`", "short": "arm 1C",
     "needle": "arm1C EAS oracleContext", "probe": "arm 1C — all-EAS via `oracleContext`",
     "family": "eas", "reference": False},
    {"key": "arm2", "label": "arm 2 — EAS plus pointer", "short": "arm 2",
     "needle": "arm2 EAS+pointer", "probe": "arm 2 — EAS plus pointer",
     "family": "eas", "reference": False},
    {"key": "arm1", "label": "arm 1 — all-EAS via EAS `Indexer`", "short": "arm 1",
     "needle": "arm1 all-EAS indexer", "probe": "arm 1 — all-EAS via EAS `Indexer`",
     "family": "eas", "reference": False},
]
READ_DEPTHS = [0, 1, 3, 7]
# The seasoning walk is per ORACLE SOURCE, and every read on this page is a three-source read, so a
# depth step of one costs three hops. Per-hop figures divide by hops x sources, never by hops alone.
READ_SOURCES = 3
# The Indexer/cycle-close growth probes the page renders. Missing any one is a hard error: the
# growth curve is the finding, and a curve with a hole in it is worse than no curve.
INDEXER_ROW_DEPTHS = [1, 2, 5]
CLOSE_ROW_DEPTHS = [1, 3, 7]
# The cycle-close row depth the PROBED Sepolia deployment actually stood at. It was the third
# deployment, and that row gains one entry per deployment, so its rows were at depth 3. This is a
# fact about the run rather than something derivable, which is exactly why it is named here and
# validated below instead of being written into the page as a literal index: the page's
# like-for-like comparison reads `closeRow[PROBED_CLOSE_ROW_DEPTH]`, and if a regenerated report
# ever stops measuring that depth the build must fail rather than render NaN.
PROBED_CLOSE_ROW_DEPTH = 3

# The pass marks, pre-registered on ENG-3922 on 2026-09-03 BEFORE any arm was measured, on Fede's
# bias concern, and never moved. They are constants here, not derived, because that is the entire
# point of pre-registering them: the bar is an INPUT to this comparison and never an output of it.
# Publication of the comparison was directed by Tim on 2026-09-04 16:18Z. C (the write-side weekly
# budget) is ENG-3922's own scorecard and is not re-rendered here; this page carries A and B.
MARK_A_CEILING = 1.5
MARK_B_ABSOLUTE = 350_000
MARK_PRE_REGISTERED_ON = "2026-09-03"
MARK_PUBLICATION_DIRECTED = "2026-09-04 16:18Z"


def _read_int(text, pattern, path, what, side="read-side"):
    """Pull one measured integer out of a report, or refuse to build.

    `side` names which panel needs the row, because this helper serves both: the read-side panel
    and (ENG-3964) the write-side running-cost terms. It defaulted to "the read-side panel needs
    it" for every caller, which sent anyone debugging a missing write-side row to the wrong half
    of the page.
    """
    match = re.search(pattern, text)
    if not match:
        sys.exit("%s: missing measured row for %s -- the %s needs it" % (path, what, side))
    return int(match.group(1).replace(",", ""))


def parse_arms_read(path):
    """Per-arm `price()` execution gas at each seasoning walk depth, from the arms report.

    Two independent test suites in that report measure the depth-0 read: `Eng3922Read` prints it
    plain, and `Eng3922Coverage` prints it again as the `coverage=none` control. They must agree --
    they are the same read under the same configuration -- so the build asserts it rather than
    trusting either. That is a genuine cross-check between two suites, not a value compared with
    itself, and it is why no equivalent row appears in the page's self-check panel.

    A missing depth is a hard error. A read-side table with a hole in it is worse than none.
    """
    text = path.read_text()
    out = {}
    for arm in READ_ARMS:
        depths = {}
        for depth in READ_DEPTHS:
            depths[str(depth)] = _read_int(
                text,
                re.escape(arm["needle"]) + r"\s+depth/source=%d price\(\) execution gas: (\d+)" % depth,
                path, "%s at walk depth %d" % (arm["key"], depth))
        control = _read_int(
            text,
            re.escape(arm["needle"]) + r"\s+coverage=none depth/source=0 price\(\) execution gas: (\d+)",
            path, "%s coverage=none control" % arm["key"])
        if control != depths["0"]:
            sys.exit("%s: %s depth-0 read is %d in Eng3922Read but %d in Eng3922Coverage's "
                     "coverage=none control; the two suites disagree and the page will not render "
                     "either" % (path, arm["key"], depths["0"], control))
        out[arm["key"]] = depths
    return out


def parse_growth(path):
    """Arm 1's two append-only Indexer growth curves, both measured in the arms report."""
    text = path.read_text()
    if PROBED_CLOSE_ROW_DEPTH not in CLOSE_ROW_DEPTHS:
        sys.exit("build-model-page.py: the probed cycle-close depth %d is not among the measured "
                 "depths %s, so the page's like-for-like comparison has nothing to read"
                 % (PROBED_CLOSE_ROW_DEPTH, CLOSE_ROW_DEPTHS))
    return {
        "indexerRow": {str(d): _read_int(text, r"Indexer row depth %d: (\d+)" % d, path,
                                         "Indexer row depth %d" % d) for d in INDEXER_ROW_DEPTHS},
        "closeRow": {str(d): _read_int(text, r"cycle-close row depth %d: (\d+)" % d, path,
                                       "cycle-close row depth %d" % d) for d in CLOSE_ROW_DEPTHS},
    }


def parse_heartbeat_variants(path):
    """Arm 2's read with and without a rebuilt per-writer heartbeat.

    These are the measured rows behind the claim that on EAS a read can take freshness from the
    attestation's own publication time rather than from a separate clock a write has to touch.
    Both are quoted verbatim; neither is the arm's headline read, which is measured separately.
    """
    text = path.read_text()
    return {
        "withHeartbeat": _read_int(
            text, r"arm2 price\(\) WITH rebuilt per-writer heartbeat: (\d+)", path,
            "arm 2 read with a rebuilt heartbeat"),
        "withoutHeartbeat": _read_int(
            text,
            r"arm2 price\(\) WITHOUT heartbeat \(freshness from attestation time only\): (\d+)",
            path, "arm 2 read without a heartbeat"),
    }


# ENG-3964: the mainnet block gas limit the boundary search was run against. It is ALSO read from
# chain into chain-data.json and rendered on the page; this constant is the figure the committed
# bench measured against, and the build asserts the two agree rather than letting them drift.
BLOCK_GAS_LIMIT = 60_000_000
# The batch sizes ENG-3964 measured while locating that boundary. The decisive pair is the last
# fitting size and the first non-fitting one; the rest are the search trace, kept so the boundary
# is reproducible rather than asserted.
BOUNDARY_SIZES = [80, 100, 200, 225, 230, 231, 250]
# The decomposition the dial-1,000 card is composed from: 1000 = 4 x 230 + 80. Both are measured
# sizes; parse_batch_boundary re-derives them from the rows and refuses if they disagree with these.
DIAL_1000_BATCH = 230
DIAL_1000_RESIDUAL = 80


def parse_eas_close_write(path):
    """The EAS cycle-close WRITE rows the running-cost model charges under the EAS dial.

    ENG-3944 charged arm 2's close at the attestation alone and excluded the pointer write that
    makes the row findable, and charged no writer bootstrap at all because none was measured.
    ENG-3964 measured both, in first AND repeat regimes, so nothing here is excluded:

      attestFirst / attestSecond  the close attestation, first and second by the same writer
      indexFirst  / indexRepeat   arm 1's Indexer write, first and later entries on that row
      pointFirst  / pointRepeat   arm 2's pointer write, cold and warm slot

    The bootstrap premium the page shows is the difference of two measured rows, never a rule about
    storage. Every row is cooled on EVERY address its call touches -- EAS, the SchemaRegistry it
    reads the schema from, and the Indexer or pointer being written -- in both halves of each pair.
    """
    text = path.read_text()
    return {
        "attestOnly": _read_int(
            text,
            r"EAS arms, cycle close attestation WITHOUT root \(round 2\) -- WHOLE TRANSACTION: (\d+)",
            path, "EAS round-2 cycle-close attestation", "write-side cycle-close term"),
        "arm1Indexed": _read_int(
            text, r"arm1 cycle close, attest \+ index -- WHOLE TRANSACTIONS: (\d+)",
            path, "arm 1 cycle close, attest + index", "write-side cycle-close term"),
        "attestFirst": _read_int(
            text, r"cycle close attestation FIRST by the writer -- WHOLE TRANSACTION: (\d+)",
            path, "EAS cycle-close attestation, first by the writer", "write-side cycle-close term"),
        "attestSecond": _read_int(
            text, r"cycle close attestation SECOND by the same writer -- WHOLE TRANSACTION: (\d+)",
            path, "EAS cycle-close attestation, second by the same writer", "write-side cycle-close term"),
        "indexFirst": _read_int(
            text, r"arm1 cycle close, Indexer write FIRST on the row -- WHOLE TRANSACTION: (\d+)",
            path, "arm 1 cycle-close Indexer write, first on the row", "write-side cycle-close term"),
        "indexRepeat": _read_int(
            text, r"arm1 cycle close, Indexer write REPEAT on the row -- WHOLE TRANSACTION: (\d+)",
            path, "arm 1 cycle-close Indexer write, repeat on the row", "write-side cycle-close term"),
        "pointFirst": _read_int(
            text, r"arm2 cycle close, pointer write FIRST on the row -- WHOLE TRANSACTION: (\d+)",
            path, "arm 2 cycle-close pointer write, first on the row", "write-side cycle-close term"),
        "pointRepeat": _read_int(
            text, r"arm2 cycle close, pointer write REPEAT on the row -- WHOLE TRANSACTION: (\d+)",
            path, "arm 2 cycle-close pointer write, repeat on the row", "write-side cycle-close term"),
    }


def assert_dial_1000_decomposition(path):
    """The dial-1,000 split must agree with the boundary the rows actually show.

    Run FIRST, before anything parses rows at those sizes. `parse_attribute_writes` reads the
    attribute legs at DIAL_1000_BATCH and DIAL_1000_RESIDUAL, so if that constant moves without the
    rows being re-measured, the attribute parser fails on a missing row and this check -- the one
    that can explain what actually went wrong -- never runs. The build refused either way; it just
    refused with the wrong reason, which sends the next person looking in the wrong place.
    """
    text = path.read_text()
    attest = {}
    for n in BOUNDARY_SIZES:
        match = re.search(r"EAS multiAttest n=%d -- WHOLE TRANSACTION: (\d+)" % n, text)
        if match:
            attest[n] = int(match.group(1))
    fits = sorted(n for n, g in attest.items() if g <= BLOCK_GAS_LIMIT)
    if not fits:
        return
    n_max = fits[-1]
    if n_max != DIAL_1000_BATCH or 1000 % n_max != DIAL_1000_RESIDUAL:
        sys.exit("build-model-page.py: the measured boundary is n_max=%d with residual %d, but the "
                 "dial-1,000 decomposition is set to %d + %d. Both write streams are composed at "
                 "that split, so re-measure the price AND attribute legs at the new sizes before "
                 "moving it" % (n_max, 1000 % n_max, DIAL_1000_BATCH, DIAL_1000_RESIDUAL))


def parse_attribute_writes(path):
    """ENG-3964 item 4: what an attribute write costs on each EAS arm.

    Composed the way the price term is -- the attestation PLUS the write that makes it findable --
    because a record the arm cannot find is a record it does not have. The lookup row is per
    (token, attribute), so a token's FIRST attribute write pays a cold row and later ones do not;
    both regimes are measured at the 100 batch so the model can charge them apart, exactly as it
    does on the bespoke layer.
    """
    text = path.read_text()

    def batch(label, sizes, suffix=""):
        return {str(n): _read_int(
            text,
            r"EAS attribute %s n=%d%s -- WHOLE TRANSACTION: (\d+)" % (label, n, suffix),
            path, "attribute %s n=%d%s" % (label, n, suffix), "write-side attribute term") for n in sizes}

    # The dial sizes, plus the two the dial-1,000 decomposition needs. The attribute stream is
    # composed at the SAME 4 x nMax + residual split the price stream uses, so the two remain
    # comparable on one dial; the attribute legs fit comfortably at that size and the build
    # asserts it below rather than assuming it.
    sizes = BATCH_SIZES + [DIAL_1000_RESIDUAL, DIAL_1000_BATCH]
    out = {
        "attest": batch("multiAttest", sizes),
        "indexFirst": batch("indexAttestations", sizes, " FIRST on the row"),
        "indexRepeat": batch("indexAttestations", sizes, " REPEAT on the row"),
        "pointFirst": batch("pointBatch", sizes, " FIRST on the row"),
        "pointRepeat": batch("pointBatch", sizes, " REPEAT on the row"),
    }
    for leg, rows in out.items():
        over = rows[str(DIAL_1000_BATCH)]
        if over > BLOCK_GAS_LIMIT:
            sys.exit("%s: the attribute %s leg is %s at n=%d, over the %s block limit, so the "
                     "dial-1,000 attribute composition would not be sendable"
                     % (path, leg, f"{over:,}", DIAL_1000_BATCH, f"{BLOCK_GAS_LIMIT:,}"))
    return out


def parse_batch_boundary(path, chain_gas_limit):
    """ENG-3964 item 3: the largest batch that fits in a block, located by MEASUREMENT.

    The dial offers 1,000 and a single n=1,000 attestation does not fit in a block. Rather than
    divide a per-item figure by the limit -- a projection, and one that came out a size too high --
    the bench measures candidate sizes and this reads the boundary off them: n_max is the largest
    MEASURED size that fits, and the build refuses unless the very next measured size is proven not
    to fit, so the boundary is an adjacent measured pair and not an extrapolation.
    """
    if chain_gas_limit != BLOCK_GAS_LIMIT:
        sys.exit("build-model-page.py: the bench measured against a %s gas block limit but "
                 "chain-data.json reads %s from chain; the boundary would be wrong"
                 % (f"{BLOCK_GAS_LIMIT:,}", f"{chain_gas_limit:,}"))
    text = path.read_text()
    attest = {n: _read_int(text, r"EAS multiAttest n=%d -- WHOLE TRANSACTION: (\d+)" % n, path,
                           "multiAttest n=%d" % n) for n in BOUNDARY_SIZES}
    fits = sorted(n for n, g in attest.items() if g <= BLOCK_GAS_LIMIT)
    over = sorted(n for n, g in attest.items() if g > BLOCK_GAS_LIMIT)
    if not fits or not over:
        sys.exit("%s: the measured batch sizes do not bracket the block limit; the boundary cannot "
                 "be read off them" % path)
    n_max, first_over = fits[-1], over[0]
    if first_over != n_max + 1:
        sys.exit("%s: n_max=%d and the first size measured NOT to fit is %d. The boundary is only "
                 "proven when those are ADJACENT -- measure n=%d, or the page is extrapolating"
                 % (path, n_max, first_over, n_max + 1))
    residual = 1000 % n_max
    # Belt and braces: assert_dial_1000_decomposition() has already run and would have caught this,
    # but the boundary is the thing this function exists to establish, so it checks its own premise.
    if n_max != DIAL_1000_BATCH or residual != DIAL_1000_RESIDUAL:
        sys.exit("%s: the measured boundary is n_max=%d with residual %d, but the dial-1,000 "
                 "decomposition is set to %d + %d"
                 % (path, n_max, residual, DIAL_1000_BATCH, DIAL_1000_RESIDUAL))
    legs = {}
    for key, label in (("index", "EAS indexAttestations"), ("point", "pointer pointBatch")):
        legs[key] = {str(n): _read_int(
            text, re.escape(label) + r" n=%d -- WHOLE TRANSACTION: (\d+)" % n, path,
            "%s n=%d" % (label, n)) for n in (n_max, residual)}
        if legs[key][str(n_max)] > BLOCK_GAS_LIMIT:
            sys.exit("%s: the %s leg does not fit at n=%d either; n_max is not set by the attest "
                     "leg and the page's wording would be wrong" % (path, label, n_max))
    return {
        "blockGasLimit": BLOCK_GAS_LIMIT,
        "sizes": BOUNDARY_SIZES,
        "attest": {str(n): g for n, g in attest.items()},
        "nMax": n_max,
        "firstOver": first_over,
        "residual": residual,
        "fullBatches": 1000 // n_max,
        "legs": legs,
    }


def parse_baseline_read(path):
    """The DEPLOYED aggregator reading the live round-1 fact store, at each walk depth.

    This is the anchor a reader recognises -- what a `price()` costs against the contracts that are
    on Sepolia today -- and it is deliberately NOT the denominator of pass mark A. A also has to
    hold everything but the fact layer constant, which only the calibration arm does.
    """
    text = path.read_text()
    # The source count is READ out of each row rather than pinned in the pattern, because every
    # per-hop figure on the page divides by READ_SOURCES: a baseline regenerated at a different
    # count would otherwise produce quietly wrong hop costs with no other symptom. Matching it
    # loosely and checking it is the difference between a real assertion and one that can never
    # fire, since a pattern that hardcodes "3 oracle sources" simply stops matching instead.
    depths = {}
    for depth in READ_DEPTHS:
        row = re.search(
            r"price\(\) execution gas, (\d+) oracle sources, seasoning walk depth %d: (\d+)" % depth,
            text)
        if not row:
            sys.exit("%s: missing measured row for the deployed aggregator at walk depth %d -- "
                     "the read-side panel needs it" % (path, depth))
        if int(row.group(1)) != READ_SOURCES:
            sys.exit("%s: the walk-depth-%d row is a %s-source read, but the page divides every "
                     "per-hop figure by %d sources"
                     % (path, depth, row.group(1), READ_SOURCES))
        depths[str(depth)] = int(row.group(2))
    store = re.search(r"live fact store: (0x[0-9a-fA-F]{40})", text)
    if not store:
        sys.exit("%s: cannot find the live fact store address in the report header" % path)
    return {"depths": depths, "factStore": store.group(1)}


def parse_sepolia_probes(path, fork):
    """The four real-Sepolia probe receipts from the merged evidence report.

    `price()` is a view, so an eth_call costs nothing observable; these come from a probe contract
    that performs the read inside a transaction and emits what it consumed. They are receipts, and
    they are the only read-side inputs on this page that cannot be recomputed -- which is why each
    one travels with its transaction hash.

    All four arms return the same price. That is asserted here rather than stated in prose: if a
    revision of the report ever has the arms returning different prices they are no longer
    measuring the same read, and the comparison on this page is void.
    """
    text = path.read_text()
    out, prices = {}, {}
    for arm in READ_ARMS:
        if not arm["probe"]:
            continue
        row = re.search(
            r"^\|\s*" + re.escape(arm["probe"]) + r"\s*\|\s*\*\*([\d,]+)\*\*\s*\|\s*([\d,]+)"
            r"\s*\|\s*(\d+)\s*\|\s*`(0x[0-9a-f]{64})`\s*\|",
            text, re.MULTILINE)
        if not row:
            sys.exit("%s: no Sepolia probe row for %r -- the read-side panel cites a transaction "
                     "hash for every arm it shows a chain figure for" % (path, arm["probe"]))
        # Group 2 is the whole-transaction figure. It is matched so the pattern reaches the
        # hash in group 4, and deliberately not carried onto the page: nothing renders it, and
        # the vendored evidence report is committed beside this file.
        out[arm["key"]] = {"gas": int(row.group(1).replace(",", "")), "tx": row.group(4)}
        prices[arm["key"]] = row.group(3)
    # The read-side panel's fork-versus-chain narrative is arm 1's: it explains the divergence by
    # arm 1's append-only Indexer rows, which no other arm has. If some other arm ever diverges
    # more, that explanation is attached to the wrong row, so the premise is asserted rather than
    # assumed. `fork` is passed in for exactly this check.
    gaps = {k: abs(v["gas"] - fork[k]["0"]) / fork[k]["0"] for k, v in out.items()}
    worst = max(gaps, key=gaps.get)
    if worst != "arm1":
        sys.exit("%s: the largest fork-versus-chain divergence is %s (%.1f%%), not arm1; the "
                 "read-side panel explains that divergence by arm 1's append-only Indexer rows, "
                 "and that explanation no longer fits the data"
                 % (path, worst, gaps[worst] * 100))
    distinct = sorted(set(prices.values()))
    if len(distinct) != 1:
        sys.exit("%s: the probe rows return different prices (%s); the arms are not measuring the "
                 "same read and the comparison is void" % (path, ", ".join(distinct)))
    return {"probes": out, "priceReturned": distinct[0]}


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

    # ENG-3938: the write-side batch figures for both arms. The bespoke single-write baseline is
    # the ENG-3913 first write measured in this repo (bench-rows.txt); the EAS arm has no ENG-3913
    # figure, so its baseline is ENG-3922's multiAttest at n=1, which is a single attest.
    arms_report = HERE / "reports" / "eng3922-arms.txt"
    # FIRST, before any parser reads a row at the dial-1,000 decomposition sizes.
    assert_dial_1000_decomposition(arms_report)
    ops = parse_arms_batch(arms_report)
    source = parse_source(HERE / "reports" / "eng3922-source.txt")
    assert_sidecar_row_counts(source, arms_report, 128)
    batch = {
        "sizes": BATCH_SIZES,
        "source": source,
        # Every measured batched op, {n: {total, perItem}}. The template composes per-arm write
        # costs from these and every addend on the page cites its op here.
        "ops": ops,
        # Bespoke: a single fact is one writePrice (the ENG-3913 first write), so the batch dial
        # at 1 reproduces that per the verification bar. writePriceBatch is the batch entrypoint;
        # its measured n=1 is shown as its own row so the batching question reads off measured rows.
        "bespoke": {
            "single": {
                "scenario": "writePrice:first",
                "gas": rows["writePrice:first"]["txTotal"],
                "source": "reports/bench-rows.txt (ENG-3913)",
            },
            "batchOp": "writePriceBatch",
        },
        # EAS: each sub-arm's per-item write is the COMPLETE, additive cost -- a record the arm
        # cannot find is a record it does not have. Arm 1 (all-EAS Indexer) pays attest plus the
        # separate indexAttestations write; arm 2 (EAS + pointer) pays attest plus the pointer
        # write. Every addend is a measured op above, so no number is prose-only.
        "eas": {
            "arms": [
                {"key": "arm1", "label": "all-EAS Indexer",
                 "note": "multiAttest creates the record; indexAttestation is a separate write, and "
                         "the Indexer is not deployed on Ethereum mainnet.",
                 "addends": ["multiAttest", "indexAttestations"]},
                {"key": "arm2", "label": "EAS + pointer",
                 "note": "an ownerless pointer contract of our own supplies the (writer, token, "
                         "kind) lookup the mainnet-absent Indexer would.",
                 "addends": ["multiAttest", "pointBatch"]},
            ],
            # multiRevoke is the revoke cost, shown as context; it is not part of the write.
            "related": ["multiRevoke"],
            # ENG-3944: the cycle-close WRITE the running-cost model charges under the EAS dial.
            # arm 1's is measured complete; arm 2's is measured only as far as the attestation.
            "close": parse_eas_close_write(arms_report),
            # ENG-3964: the attribute term, and the batch-1,000 boundary the dial needs.
            "attribute": parse_attribute_writes(arms_report),
            "boundary": parse_batch_boundary(arms_report, chain["now"]["gasLimit"]),
        },
    }
    # Labels for the addend ops, so the table can name each measured row it sums.
    batch["opLabels"] = {
        "multiAttest": "multiAttest",
        "indexAttestations": "indexAttestations",
        "pointBatch": "pointBatch",
        "writePriceBatch": "writePriceBatch",
        "multiRevoke": "multiRevoke",
    }

    # ENG-3944: the read side, from the same three merged ENG-3922 reports (55058ab0). Only the
    # raw measured integers travel onto the page: every ratio, per-hop cost, percentage and
    # projection the read-side panel shows is composed in the page's own JS from these, so a
    # reviewer verifies them by reading the rendered DOM rather than by grepping index.html.
    fork_rows = parse_arms_read(arms_report)
    read = {
        "arms": [{k: arm[k] for k in ("key", "label", "short", "family", "reference")}
                 for arm in READ_ARMS],
        "depths": READ_DEPTHS,
        "sources": READ_SOURCES,
        "indexerRowDepths": INDEXER_ROW_DEPTHS,
        "closeRowDepths": CLOSE_ROW_DEPTHS,
        "probedCloseRowDepth": PROBED_CLOSE_ROW_DEPTH,
        "fork": fork_rows,
        "growth": parse_growth(arms_report),
        "heartbeat": parse_heartbeat_variants(arms_report),
        "deployed": parse_baseline_read(HERE / "reports" / "eng3922-baseline.txt"),
        "sepolia": parse_sepolia_probes(HERE / "reports" / "eng3922-sepolia-evidence.md", fork_rows),
        "marks": {
            "aCeiling": MARK_A_CEILING,
            "bAbsolute": MARK_B_ABSOLUTE,
            "preRegisteredOn": MARK_PRE_REGISTERED_ON,
            "publicationDirected": MARK_PUBLICATION_DIRECTED,
        },
        # The paths these reports have on `main`, for citation. The vendored copies under
        # reports/ are byte-identical to them at the commit in the provenance sidecar.
        "reports": {
            "arms": "bench-reports/eng3922-arms.txt",
            "baseline": "bench-reports/eng3922-baseline.txt",
            "evidence": "bench-reports/eng3922-sepolia-evidence.md",
        },
        "source": source,
    }

    meta = {
        "commit": git("rev-parse", "HEAD"),
        "commitShort": git("rev-parse", "--short", "HEAD"),
        "historyDepth": 48,
        "reportHeader": (HERE / "reports" / "bench-rows.txt").read_text().split("\n\n")[0],
    }

    meta["inputDigest"] = input_digest()

    payload = json.dumps(
        {"rows": rows, "compare": compare, "chain": chain, "meta": meta, "batch": batch,
         "read": read},
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
