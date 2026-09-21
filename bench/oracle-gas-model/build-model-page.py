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
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
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
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
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
    # ENG-3938: the write-side batch measurements for both arms, from ENG-3922's arms report,
    # plus the provenance sidecar. ENG-3964 REGENERATED the arms report with this repo's harness
    # at ENG-3922's pinned fork block, so it is no longer byte-identical to 55058ab0; the sidecar
    # records that regeneration. Both in INPUTS so the digest tracks either one changing.
    "reports/eng3922-arms.txt",
    "reports/eng3922-source.txt",
    # ENG-3944: the read side. The arms report already carried the per-arm price() rows; the
    # baseline report carries the deployed aggregator's read, and the Sepolia evidence carries
    # the four real-transaction probe receipts that corroborate the fork. These TWO are vendored
    # verbatim and byte-identical to 55058ab0; the arms report above is not (see ENG-3964). All
    # four eng3922-* files are in INPUTS so the digest tracks them.
    #
    # NOTE: this file is NOT in INPUTS. The digest is over what the page is built FROM, not the
    # builder, so editing a comment here -- including this one -- does not move the digest.
    "reports/eng3922-baseline.txt",
    "reports/eng3922-sepolia-evidence.md",
    # ENG-4342: the SHIPPED rows. Unlike every other input this one is not a Foundry measurement
    # but a set of real Sepolia transactions of the round-3 fact store, read from the chain by
    # collect-shipped-writes.py over a window pinned to a final block. In INPUTS so the digest
    # tracks a re-collection, and because the summary card at the top of the page is quoted
    # entirely from it.
    "shipped-writes.json",
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
    return sum(1 for line in path.read_text(encoding="utf-8").splitlines()
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
    for line in path.read_text(encoding="utf-8").splitlines():
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
    # `armsRowsAfter` and `armsRowsBefore` are checked against the committed report. `armsRowsMoved`
    # CANNOT be: recomputing it needs the base revision, and a committed file cannot reach git. All
    # this can enforce is that a non-zero count carries its reason. The count itself is a claim a
    # reviewer must verify by comparison, and the sidecar says so rather than letting the presence
    # of a guard imply the number is covered.
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
    text = path.read_text(encoding="utf-8")
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
    text = path.read_text(encoding="utf-8")
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
    text = path.read_text(encoding="utf-8")
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
    text = path.read_text(encoding="utf-8")
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
    text = path.read_text(encoding="utf-8")
    return {
        # `attestOnly` and `arm1Indexed` were parsed here until ENG-3964 measured both arms' closes
        # properly. Nothing reads them now, so nothing ships them: a payload field no template
        # consumes is a figure that can go stale with no symptom.
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
    text = path.read_text(encoding="utf-8")
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
    text = path.read_text(encoding="utf-8")

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
    text = path.read_text(encoding="utf-8")
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
    text = path.read_text(encoding="utf-8")
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
    text = path.read_text(encoding="utf-8")
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


# ENG-4342: the projection the shipped batch is reconciled against.
#
# These are NOT chain reads and NOT Foundry rows. They are the batch-size model
# fabrica-v3-api#1903 published on ENG-4204 *before* the first scheduled pass ran, carried here
# as pre-registered inputs — the same treatment the read side's pass marks get — so the page can
# compare a prediction with a measurement rather than a measurement with itself. The model is
# `gas(n) = fixedGas + marginalGas * n`, where `marginalGas` was derived from the writer's own
# two-fact transaction on 2026-09-18 and `fixedGas` was an assumed intrinsic. Both the derivation
# and the quoted figures are re-checked against the chain in `parse_shipped`, so a typo here
# fails the build rather than misstating what was predicted.
SHIPPED_PROJECTION = {
    "fixedGas": 24_700,
    "quotedN": 25,
    "quotedTotal": 1_887_175,
    "quotedPerFact": 75_487,
    "source": "ENG-4204 / fabrica-v3-api#1903, batch-size table, posted 2026-09-18",
    # prycd's first broadcast, the two-fact transaction the marginal rate was derived from.
    "baselineTx": "0xf42aac9d84a5e93f0e533d95ad2a03eff5e9bd818e563436a0d789300d40a674",
    # The 24-fact batch of the first scheduled pass: the largest batch the keeper has sent, and
    # the row the summary card and the reconciliation are both quoted from.
    "headlineTx": "0xfe757d9c6ba9f7d8fa4a638a181983ecbd739b6d9ef3b8535e6d291fdec79a66",
}
# The book sizes the summary card prices, from ENG-3913's original brief ("a quote at those three
# scales"), and the two shipped inputs the card holds fixed. Both are asserted against the chain.
SHIPPED_SCALE_TOKENS = [100, 1_000, 100_000]
SHIPPED_PRICE_SOURCES = 3
SHIPPED_CYCLES_PER_DAY = 1
# The price fact kind, `keccak256("price")`, taken from the kinds actually observed rather than
# hard-coded: the reconciliation compares price batches with price batches, and a token-wide
# score or attribute batch writes a different number of storage words per fact.
SHIPPED_PRICE_KIND_SOURCE = "the kind written by every keeper price batch in the window"


def _shipped_fit(rows, path, what):
    """Solve `exec(n) = fixed + marginal * n` on `rows` and refuse anything but an exact fit.

    The whole reconciliation rests on the claim that a batched write is linear in the fact count
    with a per-transaction fixed term, so the claim is solved from the two extreme batch sizes and
    then CHECKED against every row, including the ones it was solved from. A residual of even one
    gas means the page's decomposition is wrong, and a wrong decomposition presented as an exact
    one is worse than no decomposition: the build stops.
    """
    if len(rows) < 2:
        sys.exit("%s: %s has %d batch size(s); a fixed-plus-marginal fit needs at least two"
                 % (path, what, len(rows)))
    rows = sorted(rows, key=lambda r: r["facts"])
    lo, hi = rows[0], rows[-1]
    if lo["facts"] == hi["facts"]:
        sys.exit("%s: %s has only one distinct batch size (%d)" % (path, what, lo["facts"]))
    span = hi["execGas"] - lo["execGas"]
    steps = hi["facts"] - lo["facts"]
    if span % steps:
        sys.exit("%s: %s is not linear in the fact count: %d gas over %d facts is not a whole "
                 "number per fact" % (path, what, span, steps))
    marginal = span // steps
    fixed = hi["execGas"] - marginal * hi["facts"]
    checked = []
    for row in rows:
        fitted = fixed + marginal * row["facts"]
        if fitted != row["execGas"]:
            sys.exit("%s: %s does not fit exec(n) = %d + %d*n: %s at n=%d measured %d, fitted %d"
                     % (path, what, fixed, marginal, row["hash"], row["facts"], row["execGas"],
                        fitted))
        checked.append({"hash": row["hash"], "facts": row["facts"], "execGas": row["execGas"],
                        "fittedGas": fitted})
    return {"fixedExecGas": fixed, "marginalExecGas": marginal, "rows": checked}


def assert_ascending(name, values):
    """Refuse a depth list whose literals are not in ascending order.

    READ_DEPTHS, INDEXER_ROW_DEPTHS and CLOSE_ROW_DEPTHS are read by the page as `[0]` and
    `[len-1]` endpoints of a walk. Nothing about the literal enforces the order those lookups
    assume, and a reordered edit would render a wrong span with no error -- exactly the defect
    the setLock gas span turned out to be. Asserted here rather than sorted at the point of use
    so that a scrambled literal fails the build loudly instead of being silently corrected.
    """
    if list(values) != sorted(values):
        sys.exit("%s is not ascending (%s); the page reads its first and last entries as the "
                 "endpoints of a walk" % (name, ", ".join(str(v) for v in values)))
    if len(set(values)) != len(values):
        sys.exit("%s contains a duplicate (%s)" % (name, ", ".join(str(v) for v in values)))


def parse_shipped(path):
    """ENG-4342: the SHIPPED rows, from `shipped-writes.json` (see collect-shipped-writes.py).

    This is the only input on the page that is a real transaction on a real chain rather than a
    Foundry measurement, so it is also the only one where "did it revert?" and "was that really
    the whole transaction set?" are live questions. Both are answered in the file and asserted
    here; a collection that cannot answer them does not reach the page.
    """
    data = json.loads(path.read_text(encoding="utf-8"))
    if data["chain"]["chainId"] != 11155111:
        sys.exit("%s: chainId %s is not Sepolia" % (path, data["chain"]["chainId"]))
    cross = data["etherscanCrossCheck"]
    if not (cross.get("ran") and cross.get("ok") and cross.get("matchesLogDerivedSet")):
        sys.exit("%s: the Etherscan cross-check did not run or did not agree with the log-derived "
                 "transaction set; the page cannot claim the set is complete. Re-collect with "
                 "--etherscan-cross-check." % path)
    if cross["failed"]:
        sys.exit("%s: %d transaction(s) in the window reverted (%s). The page's shipped rows read "
                 "as successful writes; a reverted batch needs its own row before this builds."
                 % (path, len(cross["failed"]), ", ".join(cross["failed"])))

    # Every derived field in the collection is RECOMPUTED here from the fields it derives from,
    # rather than trusted. The collection is a committed JSON file: it can be hand-edited, merged
    # badly, or truncated, and until this check existed a one-gas edit to `gasUsed` passed the
    # build cleanly because the fit reads the stored `execGas` and never looked. A page whose
    # arithmetic is its whole claim cannot take its own inputs on trust.
    const = data["gasConstants"]
    for t in data["transactions"]:
        fee = int(t["feeWei"])
        if fee != t["gasUsed"] * int(t["effectiveGasPriceWei"]):
            sys.exit("%s: %s feeWei %d != gasUsed %d x effectiveGasPrice %s"
                     % (path, t["hash"], fee, t["gasUsed"], t["effectiveGasPriceWei"]))
        if t["op"] not in ("writeFacts", "writeFact"):
            continue
        exec_gas = t["gasUsed"] - const["txBase"] - t["calldata"]["gas"]
        if exec_gas != t["execGas"]:
            sys.exit("%s: %s execGas %d but gasUsed − %d intrinsic − %d calldata = %d"
                     % (path, t["hash"], t["execGas"], const["txBase"], t["calldata"]["gas"],
                        exec_gas))
        if t["gasUsed"] // t["facts"] != t["gasPerFact"]:
            sys.exit("%s: %s gasPerFact %d but %d // %d = %d"
                     % (path, t["hash"], t["gasPerFact"], t["gasUsed"], t["facts"],
                        t["gasUsed"] // t["facts"]))
        if t["firstWrites"] + t["repeatWrites"] != t["facts"]:
            sys.exit("%s: %s has %d first + %d repeat writes, which is not its %d facts"
                     % (path, t["hash"], t["firstWrites"], t["repeatWrites"], t["facts"]))
        cd = t["calldata"]
        if cd["headGas"] + cd["bodyGas"] != cd["gas"] or cd["headBytes"] + cd["bodyBytes"] != cd["bytes"]:
            sys.exit("%s: %s calldata head + body does not sum to the whole" % (path, t["hash"]))

    txns = data["transactions"]
    writes = [t for t in txns if t["op"] in ("writeFacts", "writeFact")]
    keeper_writes = [t for t in writes if t["keeperSigner"]]
    if not keeper_writes:
        sys.exit("%s: no keeper writes in the window; there is nothing shipped to show" % path)
    # keeperPass is all() over a time-grouped pass, so a keeper transaction landing within
    # PASS_GAP_SECONDS of a non-keeper one makes its whole group a non-keeper pass. Keeper
    # WRITES existing therefore does not imply any keeper PASS exists, and the page quotes
    # keeperPasses[0] unguarded -- an empty list took the whole shipped panel down with a
    # TypeError rather than failing here with a message.
    if not any(p["keeperPass"] for p in data["passes"]):
        sys.exit("%s: no pass in this window is entirely keeper traffic; the shipped panel "
                 "quotes the first keeper pass and would have nothing to quote" % path)

    # The price kind is whatever the keeper's price batches actually carry. A token-wide batch
    # (score, attributes) writes a different number of words per fact and must not be fitted
    # together with price batches, so the split is by measured kind, not by assumption.
    kind_counts = {}
    for t in keeper_writes:
        for kind in t["kinds"]:
            kind_counts[kind] = kind_counts.get(kind, 0) + t["facts"]
    price_kind = max(kind_counts, key=kind_counts.get)

    def single_kind(t, kind):
        return t["kinds"] == [kind]

    # `writeFacts` only. The single-fact `writeFact` entry point decodes a struct rather than an
    # array, so it pays a different per-transaction head cost (413 gas less, measured) and does
    # not share the batch entry point's fixed term. Mixing the two would break the fit for the
    # right reason and hide it behind a wrong one.
    price_first = [t for t in keeper_writes if t["op"] == "writeFacts"
                   and single_kind(t, price_kind) and t["repeatWrites"] == 0]
    fit = _shipped_fit(price_first, path, "the keeper's first-write price batches")
    # The ENG-4203 deployment verification wrote the same entry point with a different fact shape
    # and a different sender. Its fixed term must come out identical — that is what makes the
    # fixed term a property of the transaction rather than of this keeper's data.
    other_first = [t for t in writes if t["op"] == "writeFacts"
                   and not t["keeperSigner"] and t["repeatWrites"] == 0 and len(t["kinds"]) == 1]
    independent = _shipped_fit(other_first, path, "the ENG-4203 verification batches")
    if independent["fixedExecGas"] != fit["fixedExecGas"]:
        sys.exit("%s: the fixed execution term is %d on the keeper's batches but %d on the "
                 "ENG-4203 verification batches; the page presents it as a property of the "
                 "transaction and that is no longer true"
                 % (path, fit["fixedExecGas"], independent["fixedExecGas"]))

    by_hash = {t["hash"]: t for t in txns}
    baseline = by_hash.get(SHIPPED_PROJECTION["baselineTx"])
    headline = by_hash.get(SHIPPED_PROJECTION["headlineTx"])
    for label, row in (("baselineTx", baseline), ("headlineTx", headline)):
        if row is None:
            sys.exit("%s: the %s named in SHIPPED_PROJECTION is not in the collected window"
                     % (path, label))
        if row["op"] != "writeFacts":
            sys.exit("%s: the %s is a %s, not a writeFacts batch" % (path, label, row["op"]))
    if headline["facts"] != max(t["facts"] for t in keeper_writes):
        sys.exit("%s: the headline transaction carries %d facts but the largest keeper batch in "
                 "the window carries %d; the summary card must quote the largest shipped batch"
                 % (path, headline["facts"], max(t["facts"] for t in keeper_writes)))

    # Re-derive the projection from the baseline transaction exactly as ENG-4204 derived it, and
    # refuse to carry a quoted figure this repo cannot reproduce.
    proj = dict(SHIPPED_PROJECTION)
    residual = baseline["gasUsed"] - proj["fixedGas"]
    if residual % baseline["facts"]:
        sys.exit("%s: the projection's marginal rate is not a whole number: (%d - %d) / %d"
                 % (path, baseline["gasUsed"], proj["fixedGas"], baseline["facts"]))
    proj["marginalGas"] = residual // baseline["facts"]
    proj["baselineFacts"] = baseline["facts"]
    proj["baselineGas"] = baseline["gasUsed"]
    total = proj["fixedGas"] + proj["marginalGas"] * proj["quotedN"]
    if total != proj["quotedTotal"]:
        sys.exit("%s: the projection does not reproduce: %d + %d*%d = %d, quoted %d"
                 % (path, proj["fixedGas"], proj["marginalGas"], proj["quotedN"], total,
                    proj["quotedTotal"]))
    if total // proj["quotedN"] != proj["quotedPerFact"]:
        sys.exit("%s: the projection's per-fact figure does not reproduce: %d // %d = %d, "
                 "quoted %d" % (path, total, proj["quotedN"], total // proj["quotedN"],
                                proj["quotedPerFact"]))

    # Cycle closes: two regimes, and the page names them. The first close a writer makes on a
    # store bootstraps cold words; every later one does not. If the window ever shows more than
    # two distinct close costs the page's two-regime sentence is wrong.
    closes = [t for t in txns if t["op"] == "closeCycle" and t["keeperSigner"]]
    close_gas = sorted({t["gasUsed"] for t in closes})
    if len(close_gas) != 2:
        sys.exit("%s: cycle closes show %d distinct gas figures (%s); the page states two regimes"
                 % (path, len(close_gas), ", ".join(str(g) for g in close_gas)))
    close_repeat, close_first = close_gas[0], close_gas[1]
    first_time = max(t["timestamp"] for t in closes if t["gasUsed"] == close_first)
    repeat_time = min(t["timestamp"] for t in closes if t["gasUsed"] == close_repeat)
    if first_time > repeat_time:
        sys.exit("%s: a dearer cycle close came after a cheaper one; 'first close, then repeats' "
                 "is not what happened" % path)

    # Cadence: the cycle number the closes carry, and how many days they span. The summary card
    # multiplies by cycles per month, so the claim that a cycle is a day is checked, not assumed.
    cycles = sorted({t["cycle"] for t in closes})
    if cycles != list(range(cycles[0], cycles[-1] + 1)):
        sys.exit("%s: the closed cycles %s are not consecutive; the page's one-cycle-per-day "
                 "reading does not hold" % (path, cycles))
    days = {t["timeUtc"][:10] for t in closes}
    if len(days) != len(cycles):
        sys.exit("%s: %d closed cycles across %d calendar days; a cycle is not a day in this "
                 "window" % (path, len(cycles), len(days)))

    # ENG-4342, after Tim (#engineering, 2026-09-21 13:33Z): "Repeat writes are skipped, bud …
    # if a valuation does not change by a certain percentage, we skip the write."
    #
    # The keeper's significance gate (fabrica-v3-api src/onchain-oracle-keeper/significance.ts,
    # ENG-3926) writes a price fact only on a FIRST write or when the value moves at least
    # `materialChangeBps` against the value read back from the store. So a steady-state month is
    # NOT one write per token per cycle; the cycle close is the only guaranteed per-writer work.
    #
    # The rate at which rows actually move past the threshold is a property of the valuation
    # feed, not of the configuration, and this repo cannot derive it from a bps figure. What it
    # CAN do is measure what happened: a row written in cycle c had an opportunity to be
    # rewritten in every cycle its own writer closed after c. Counting those against the repeat
    # writes that actually occurred gives an observed rate with a stated denominator, which is
    # the only rate this page is entitled to quote.
    keeper_closes = {}
    for t in txns:
        if t["op"] == "closeCycle" and t["keeperSigner"]:
            keeper_closes.setdefault(t["signer"], set()).add(t["cycle"])
    opportunities = 0
    observed = 0
    rewrite_rows = []
    for t in txns:
        if t["op"] != "writeFacts" or not t["keeperSigner"] or t["kinds"] != [price_kind]:
            continue
        later = sorted(c for c in keeper_closes.get(t["signer"], ()) if c > max(t["cycles"]))
        opportunities += t["facts"] * len(later)
        observed += t["repeatWrites"]
        rewrite_rows.append({"hash": t["hash"], "signer": t["signer"], "facts": t["facts"],
                             "writtenInCycle": max(t["cycles"]), "laterClosedCycles": later,
                             "opportunities": t["facts"] * len(later),
                             "rewrites": t["repeatWrites"]})
    if opportunities == 0:
        sys.exit("%s: no row in this window has yet had a chance to be rewritten, so the page "
                 "cannot state an observed rewrite rate at all. Collect a window that spans at "
                 "least one cycle beyond a price write." % path)
    rewrite = {
        "opportunities": opportunities,
        "observed": observed,
        # How many cycles the window actually spans. The page uses this to say "no repeat write
        # in N observed cycles" rather than "a 0% rate": four cycles cannot tell a static book
        # from one whose rows have not yet moved past the threshold, and the difference matters.
        "cyclesObserved": len(cycles),
        # The fact count that shares this denominator. The rewrite rows are PRICE rows only --
        # the token-wide score/attribute batch has different write semantics and is rightly
        # excluded -- so a sentence quoting this denominator must quote this numerator with it,
        # not the all-kinds total. (Reviewer N3: the two halves were coming from different sets.)
        "priceFacts": sum(r["facts"] for r in rewrite_rows),
        # And the complement, carried EXPLICITLY rather than left to the page to derive by
        # subtracting a differently-filtered total. `priceFacts` counts keeper `writeFacts` rows
        # of the single price kind; a keeper SINGULAR `writeFact` of a price fact is in neither
        # set, so `totalFactsShipped - priceFacts` would have labelled it a token-wide fact. The
        # window contains two `writeFact` rows already (both non-keeper, which is the only reason
        # the rendered figure is right today). Computed here over the same keeper-write basis, the
        # two halves are structurally consistent instead of arithmetically coupled.
        "excludedFacts": sum(t["facts"] for t in txns
                             if t["op"] in ("writeFacts", "writeFact") and t["keeperSigner"]
                             and not (t["op"] == "writeFacts" and t["kinds"] == [price_kind])),
        "rows": rewrite_rows,
        "thresholdBps": 100,
        "thresholdSource": "fabrica-v3-api onchainOracleKeeper.materialChangeBps, default 100 "
                           "(= 1% of the prior published price), enforced by "
                           "src/onchain-oracle-keeper/significance.ts (ENG-3926)",
        "method": "a price row first written in cycle c could have been rewritten in every cycle "
                  "its own writer closed after c; opportunities counts those, observed counts "
                  "the repeat writes that actually happened",
        "notARate": "a threshold in bps does not imply a rewrite rate: that depends on how often "
                    "valuations move past it, which is a property of the feed and is not "
                    "measured here. The page quotes the observed rate with its denominator and "
                    "offers the 100% upper bound; it does not compute a rate from the threshold.",
    }

    # The trusted price set. The summary card multiplies its per-fact figure by this count, so the
    # count and the labels are both checked against the signers the collection actually resolved.
    price_writers = data["keeperConfig"]["priceWriters"]
    if len(price_writers) != SHIPPED_PRICE_SOURCES:
        sys.exit("%s: keeperConfig names %d price writers (%s) but the summary card is built for "
                 "%d sources" % (path, len(price_writers), ", ".join(price_writers),
                                 SHIPPED_PRICE_SOURCES))
    labels = set(data["signers"].values())
    unknown = [w for w in price_writers if w not in labels]
    if unknown:
        sys.exit("%s: price writer(s) %s never appear as a sender in this window; the card would "
                 "charge for a writer the chain does not show"
                 % (path, ", ".join(unknown)))

    # Locks, grouped. Sixty near-identical rows do not belong on a page; their gas distribution
    # does, with one example hash each so any of them can be re-read from the chain.
    def group(rows):
        out = {}
        for row in rows:
            slot = out.setdefault(row["gasUsed"], {"gasUsed": row["gasUsed"], "count": 0,
                                                   "exampleHash": row["hash"]})
            slot["count"] += 1
        return sorted(out.values(), key=lambda g: -g["count"])

    locks = [t for t in txns if t["op"] == "setLock" and t["keeperSigner"]]
    # Grouped once and reused below, rather than regrouped inside the payload literal.
    #
    # The cardinality is deliberately NOT asserted. Two distinct setLock gas figures is an
    # accident of the data -- 12 gas is one byte of a tokenId that happens to be zero -- so a
    # window whose locked tokens all have the same byte pattern would legitimately show one
    # group, and a more varied window three. That is unlike the cycle close, where two regimes
    # are a property of the CONTRACT (a writer's first close allocates cold words) and so are
    # asserted above. The page derives its sentence from this list's length instead; what
    # would be a defect is an unguarded index, not an unexpected count.
    lock_groups = group(locks)
    return {
        "store": data["store"],
        "storeSource": data["storeSource"],
        "gasConstants": data["gasConstants"],
        "chain": data["chain"],
        "window": data["window"],
        "collection": data["collection"],
        "passGrouping": data["passGrouping"],
        "signers": data["signers"],
        "signerSource": data["signerSource"],
        "keeperConfig": data["keeperConfig"],
        "easWritePath": data["easWritePath"],
        "etherscanCrossCheck": cross,
        "passes": data["passes"],
        # Every batched write in the window, keeper and verification alike, in full. These are the
        # rows a reviewer re-derives from the chain, so none of them is summarised away.
        "writes": writes,
        "priceKind": price_kind,
        "priceKindSource": SHIPPED_PRICE_KIND_SOURCE,
        "fit": fit,
        "independentFit": independent,
        "projection": proj,
        "baselineTx": baseline["hash"],
        "headlineTx": headline["hash"],
        "closes": {"repeatGas": close_repeat, "firstGas": close_first,
                   "groups": group(closes), "cycles": cycles, "days": sorted(days)},
        "locks": {"groups": lock_groups, "count": len(locks)},
        "rewrite": rewrite,
        "scale": {"tokens": SHIPPED_SCALE_TOKENS, "priceSources": SHIPPED_PRICE_SOURCES,
                  "cyclesPerDay": SHIPPED_CYCLES_PER_DAY},
    }


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
    chain = json.loads((HERE / "chain-data.json").read_text(encoding="utf-8"))
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
        # The paths these reports have on `main`, for citation. The baseline and evidence copies
        # under reports/ are byte-identical to them at the commit in the provenance sidecar; the
        # arms copy is NOT -- ENG-3964 regenerated it, and the sidecar records that.
        "reports": {
            "arms": "bench-reports/eng3922-arms.txt",
            "baseline": "bench-reports/eng3922-baseline.txt",
            "evidence": "bench-reports/eng3922-sepolia-evidence.md",
        },
        "source": source,
    }

    # ENG-4342: the shipped rows. Parsed after the modelled arms so that a broken collection
    # cannot be mistaken for a broken report, and so the build fails on the shipped input with
    # its own message.
    shipped = parse_shipped(HERE / "shipped-writes.json")
    # The read-side panel takes the first and last entry of each of these as the endpoints of a
    # walk, so their order is load-bearing and nothing but this check enforces it.
    assert_ascending("READ_DEPTHS", READ_DEPTHS)
    assert_ascending("INDEXER_ROW_DEPTHS", INDEXER_ROW_DEPTHS)
    assert_ascending("CLOSE_ROW_DEPTHS", CLOSE_ROW_DEPTHS)
    # BATCH_SIZES belongs in this block for the same reason: the cost-at-scale card prices the
    # WHOLE EAS arm at `BATCH.sizes[BATCH.sizes.length - 1]`, taking the last entry as the largest
    # measured batch, and the batch-dial hint reads the same position to say where per-item attest
    # cost stops converging. Reordered to [100, 1, 10] the card would silently price EAS at the
    # n=10 row (292,983 gas/fact instead of 286,421) and the hint would name the wrong size --
    # with no error anywhere.
    assert_ascending("BATCH_SIZES", BATCH_SIZES)
    # The cost-at-scale card reads tokens[1] and tokens[2] by POSITION, so the length of this
    # list is load-bearing in the same way the depth lists' order is. A shorter list would not
    # fail: it would render the missing values as em dashes and silently drop a scale row.
    if len(SHIPPED_SCALE_TOKENS) != 3:
        sys.exit("SHIPPED_SCALE_TOKENS has %d entries (%s), not 3; the cost-at-scale card reads "
                 "its second and third entries by position"
                 % (len(SHIPPED_SCALE_TOKENS),
                    ", ".join(str(t) for t in SHIPPED_SCALE_TOKENS)))
    assert_ascending("SHIPPED_SCALE_TOKENS", SHIPPED_SCALE_TOKENS)
    # Read the template before validating: the assertions below derive what they check --
    # the gas-anchor labels and the EAS arm key the page looks up by name -- from its text,
    # so that no list here has to be kept in agreement with a list there.
    template = (HERE / "page-template.html").read_text(encoding="utf-8")

    # The summary card says "three pinned gas scenarios" and renders one column per anchor that is
    # pinned to a named historical block. `now` is re-read on every chain-data refresh and is
    # deliberately not one of them. If the anchor set ever changes, the card's own sentence goes
    # stale, so the count is asserted rather than trusted to stay at three.
    pinned = [a for a in chain["gasAnchors"] if a["label"] != "now"]
    if len(pinned) != 3:
        sys.exit("chain-data.json has %d pinned gas anchors (%s), not 3; the summary card's "
                 "'three pinned gas scenarios' no longer describes the page"
                 % (len(pinned), ", ".join(a["label"] for a in pinned)))
    # The count above says how many pinned anchors there are; it cannot say anything about the
    # anchors the page looks up BY NAME and then dereferences -- `now`, `extremely high` and
    # `historical peak` are all found with .find(a => a.label === "...") and immediately read.
    # A chain-data.json refresh that drops or renames any of them would build clean and throw
    # at init, blanking the whole page: the keeperPasses[0] shape again.
    #
    # Rather than restate those names here -- a second list that must agree with the first, the
    # defect this page keeps producing -- read them out of the template itself and require each
    # to resolve exactly once. Any future lookup added to the template is covered automatically.
    wanted = sorted(set(re.findall(
        r'gasAnchors\.find\(\s*\w+\s*=>\s*\w+\.label === "([^"]+)"\)', template)))
    if not wanted:
        sys.exit("page-template.html no longer looks up any gas anchor by name; this assertion "
                 "was reading that list out of the template and now has nothing to check")
    have = [a["label"] for a in chain["gasAnchors"]]
    for label in wanted:
        if have.count(label) != 1:
            sys.exit("page-template.html dereferences the gas anchor labelled %r, which appears "
                     "%d times in chain-data.json (labels: %s)"
                     % (label, have.count(label), ", ".join(have)))

    # Same shape on the EAS write arms: the template picks its headline arm by key and, when the
    # EAS layer is selected, also requires a second arm for the "other arm" figure. The key is a
    # template literal; read it back rather than duplicating it.
    headline = re.search(r'const EAS_HEADLINE_ARM = "([^"]+)";', template)
    if not headline:
        sys.exit("page-template.html no longer declares EAS_HEADLINE_ARM; the builder reads that "
                 "literal to check the arm it names is present in the emitted data")
    arm_keys = [a["key"] for a in batch["eas"]["arms"]]
    if arm_keys.count(headline.group(1)) != 1:
        sys.exit("page-template.html reads EAS arm %r by key and dereferences it, but the emitted "
                 "arms are %s" % (headline.group(1), ", ".join(arm_keys)))
    if len(set(arm_keys)) < 2:
        sys.exit("the EAS layer quotes a second arm alongside the headline; emitted arm keys are "
                 "%s, which cannot supply one" % ", ".join(arm_keys))

    meta = {
        "commit": git("rev-parse", "HEAD"),
        "commitShort": git("rev-parse", "--short", "HEAD"),
        "historyDepth": 48,
        "reportHeader": (HERE / "reports" / "bench-rows.txt").read_text(encoding="utf-8").split("\n\n")[0],
    }

    meta["inputDigest"] = input_digest()

    payload = json.dumps(
        {"rows": rows, "compare": compare, "chain": chain, "meta": meta, "batch": batch,
         "read": read, "shipped": shipped},
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

    if PLACEHOLDER not in template:
        sys.exit("page-template.html no longer contains the %r placeholder; refusing to write a "
                 "page with no data in it" % PLACEHOLDER)
    html = template.replace(PLACEHOLDER, payload)
    if PLACEHOLDER in html:
        sys.exit("placeholder survived substitution; refusing to write")
    # len() on a str is a CHARACTER count. This page is UTF-8 and carries em dashes, arrows and
    # multiplication signs, so its byte length runs several hundred above its character length
    # (274,605 vs 274,045 at the time of writing). The figure below is labelled "bytes", is
    # quoted into FV comments, and gets compared against `ls -l` -- so it has to be bytes.
    html_bytes = len(html.encode("utf-8"))

    target = HERE / "index.html"
    if check_only:
        if not target.exists():
            sys.exit("--check: index.html does not exist")
        current = target.read_text(encoding="utf-8")
        # The git-meta fields record the commit the page was BUILT from, which is necessarily
        # the parent of the commit that carries the page -- committing the page changes HEAD.
        # So they differ on every head after the one that built it, and comparing them would
        # make --check fail for every reviewer on every commit. They are provenance, not
        # content. The content identity is `inputDigest`, which hashes the inputs and not the
        # repository, and that IS compared.
        if normalise(current) == normalise(html):
            print("--check: index.html is exactly what its committed inputs produce "
                  f"({html_bytes:,} bytes, {len(rows)} measured scenarios)")
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

    target.write_text(html, encoding="utf-8")
    print("wrote", target, f"({html_bytes:,} bytes, {len(rows)} measured scenarios)")


if __name__ == "__main__":
    main()
