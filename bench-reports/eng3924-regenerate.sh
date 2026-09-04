#!/usr/bin/env bash
# ENG-3924 — regenerate the measured gas table in the round-2 fact-store deployment artifact.
#
# Three separate stale-table defects were caught in ENG-3922's review, every one of them a
# hand-maintained copy of a generated number. The gas table in
# deployment-artifacts/ENG-3924-round2-fact-store.md is therefore emitted by this script rather
# than typed, and a reviewer can rerun it to check any cell.
#
#   usage:  bench-reports/eng3924-regenerate.sh
#
# Do NOT add --gas-report. Its inspector perturbs the in-test gasleft() deltas the bench reads;
# that is the defect round 1 of ENG-3922's review caught.
set -euo pipefail
cd "$(dirname "$0")/.."

BENCH_CMD='forge test --match-contract Eng3924FactStoreGasTest -vv'
REPORT='bench-reports/eng3924-fact-store-gas.txt'
DOC='deployment-artifacts/ENG-3924-round2-fact-store.md'

FORGE_VERSION="$(forge --version 2>/dev/null | head -1 || true)"
FORGE_COMMIT="$(forge --version 2>/dev/null | grep -i 'Commit SHA' | awk '{print $3}' || true)"
FORGE_VERSION="${FORGE_VERSION:-unknown (forge --version produced no output)}"
FORGE_COMMIT="${FORGE_COMMIT:-unknown}"

raw="$(eval "$BENCH_CMD")"

# N5: the report is staged to a temp file and published only after every check below has passed.
# Writing straight to $REPORT truncated the committed report at redirect time, so a run that then
# failed validation left a damaged artifact behind — the detection happened after the destruction.
# The same rule applies to the document: this script now mutates nothing at all unless it succeeds.
TMP_REPORT="$(mktemp)"
trap 'rm -f "$TMP_REPORT"' EXIT

{
  cat <<EOF
# ENG-3924 round-2 fact store — whole-transaction gas
#
# PROVENANCE
#   forge        : $FORGE_VERSION
#   forge commit : $FORGE_COMMIT
#   profile      : default (foundry.toml: optimizer=true, optimizer_runs=1, via_ir=false)
#   command      : $BENCH_CMD
#   regenerate   : bench-reports/eng3924-regenerate.sh
#   contract     : src/FabricaFactStore.sol
#   basis        : whole transaction = 21,000 intrinsic + EIP-2028 calldata + execution.
#                  One scenario per test function. Storage slots are cooled with vm.cool and the
#                  ACCOUNT is then re-warmed with a BALANCE read, because a real transaction
#                  starts with tx.to warm (EIP-2929) and its storage slots cold. The calldata
#                  cost is computed BEFORE the measurement window. The getLiveFact row is a view:
#                  execution only, no intrinsic and no calldata, because that is what an
#                  aggregator pays inside price().
#   cross-check  : against real Sepolia receipts, see the artifact. Agreement is ~1% on every row
#                  that has a receipt; the residual is the harness CALL overhead.
#
EOF
  echo "$raw" | grep 'ENG-3924 gas:' | sed 's/^[[:space:]]*//' | sort
} > "$TMP_REPORT"

python3 - "$TMP_REPORT" "$DOC" "$REPORT" <<'PY'
import os
import re
import sys

staged, doc, report = sys.argv[1], sys.argv[2], sys.argv[3]

# The exact scenario set this bench is expected to emit. A row that disappears (deleted test,
# skipped test, renamed label) or is emitted twice must fail the run rather than silently
# shrinking both generated artifacts — CodeRabbit 3936190714.
EXPECTED = [
    "writeFact regime 1 (fresh row, no history push)",
    "writeFact regime 2 (cold history slot + cold counter)",
    "writeFact regime 3-48 (cold history slot, warm counter)",
    "writeFact regime 49+ (ring overwrite)",
    "closeCycle (first close, cold slot)",
    "closeCycle (subsequent close, warm slot)",
    "setLock (lock, cold slot)",
    "setMinValidCycle (kills every fact below the floor)",
    "getLiveFact (cold, execution only, as read inside price())",
    "cycle projection, fresh rows, per fact (one tx per fact)",
    "cycle projection, 1,000 tokens x 3 oracle sources = 3,000 facts",
]

rows = []
for line in open(staged, encoding="utf-8"):
    match = re.match(r"ENG-3924 gas:\s*(.+?)\s*=\s*(\d+)\s*$", line.strip())
    if match:
        rows.append((match.group(1), int(match.group(2))))

labels = [label for label, _ in rows]
duplicates = sorted({label for label in labels if labels.count(label) > 1})
missing = [label for label in EXPECTED if label not in labels]
unexpected = [label for label in labels if label not in EXPECTED]
if duplicates:
    sys.exit("duplicate gas rows: " + "; ".join(duplicates))
if missing:
    sys.exit("gas rows MISSING (deleted or skipped test?): " + "; ".join(missing))
if unexpected:
    sys.exit("unexpected gas rows (add them to EXPECTED once reviewed): " + "; ".join(unexpected))

cells = dict(rows)
table = ["| Scenario | Whole-transaction gas |", "| -- | -- |"]
for label in EXPECTED:
    table.append("| `{}` | {:,} |".format(label, cells[label]))
block = (
    "<!-- GENERATED:gas do not edit by hand; bench-reports/eng3924-regenerate.sh rewrites this -->\n\n"
    + "\n".join(table)
    + "\n\n<!-- /GENERATED:gas -->"
)

text = open(doc, encoding="utf-8").read()
pattern = re.compile(r"<!-- GENERATED:gas.*?<!-- /GENERATED:gas -->", re.DOTALL)
if not pattern.search(text):
    sys.exit("no GENERATED:gas block in " + doc)
# The CANDIDATE document, not yet on disk. The prose check runs against this, so a drifting
# figure fails the run without having rewritten anything.
candidate = pattern.sub(lambda _: block, text)

# ---------------------------------------------------------------------------
# Prose cross-check. Prose cannot be regenerated, so it is verified instead.
#
# The first version of this guard asked whether each cited figure was PRESENT in the document.
# That is too weak, and a probe proved it: changing one of two copies of a derived figure left the
# other copy present, so the check passed while the document carried a wrong number. Presence of
# the right figure says nothing about the absence of a wrong one.
#
# So the check is inverted. Every gas-shaped figure appearing anywhere in the measured-gas section
# must be EXPLAINABLE: either it equals a row the bench just produced, or a value derived from one,
# or it is allow-listed below with the reason it is a constant rather than a measurement. Any
# unexplained gas figure fails the run, which is what catches a stale copy.
DERIVED = {
    "~{:,}M".format(round(cells["cycle projection, 1,000 tokens x 3 oracle sources = 3,000 facts"] / 1e6)):
        "3,000-fact projection in millions",
    "~{:,}M".format(round(cells["writeFact regime 3-48 (cold history slot, warm counter)"] * 3000 / 1e6)):
        "steady-state cycle, regime 3-48 x 3,000",
}
# Constants that are not measurements of this contract. Each needs a reason to be here.
ALLOWED = {
    "74,949": "ENG-3922's batched arm-3 figure, quoted to say it does NOT carry over",
    "450,000,000": "ENG-3922 pass mark C",
    "~470M": "the retracted first-revision projection, named so the correction is legible",
    "21,000": "EIP-2028 intrinsic transaction cost",
    "2,500": "cold-account access premium, defect 1",
    "58,000": "magnitude of defect 2",
    "61,500": "combined per-write overstatement",
    "1,000": "token count in the projection",
    "3,000": "fact count in the projection",
    # Chain facts, not measurements of this bench: the receipts the bench is cross-checked against.
    # These cannot be regenerated, so each carries the transaction that produced it.
    "97,703": "receipt gasUsed, writeFact fresh row, tx 0x94741402...280f",
    "46,539": "receipt gasUsed, setLock, tx 0x50a0b480...8a0b",
    "48,649": "receipt gasUsed, closeCycle first, tx 0xba6e299e...6619",
}

section = candidate[candidate.index("## Measured write cost"):candidate.index("## Deployed addresses")]
legal = {"{:,}".format(value) for value in cells.values()}
legal |= set(DERIVED)
legal |= set(ALLOWED)
found = set(re.findall(r"~\d+M\b", section)) | set(re.findall(r"\b\d{1,3}(?:,\d{3})+\b", section))
unexplained = sorted(found - legal)
if unexplained:
    sys.exit(
        "PROSE DRIFT: gas figure(s) in the measured-gas section match no bench row, no derived "
        "value and no allow-listed constant: " + ", ".join(unexplained) +
        ". Either the prose is stale, or add the figure to ALLOWED with a reason."
    )
# And the derived figures must actually still be stated, so a correction cannot silently drop them.
for phrase, description in DERIVED.items():
    if phrase not in section:
        sys.exit("PROSE DRIFT: {} ({}) is no longer stated in the document.".format(phrase, description))

# Every check has passed: now, and only now, publish the document.
with open(doc + ".tmp", "w", encoding="utf-8") as handle:
    handle.write(candidate)
os.replace(doc + ".tmp", doc)
print("rewrote the gas table in " + doc + " from " + report)
print(
    "prose cross-check: {} gas figures in the section all explained; {} derived figures present".format(
        len(found), len(DERIVED)
    )
)
PY

# Every check passed, so the staged report becomes the committed one. Under `set -e` a failing
# python above aborts the script before this line and the committed report is left untouched.
mv "$TMP_REPORT" "$REPORT"
trap - EXIT
