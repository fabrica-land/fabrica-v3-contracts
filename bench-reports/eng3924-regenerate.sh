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
#                  One scenario per test function, vm.cool(store) immediately before the
#                  measured call. The getLiveFact row is a view: execution only, no intrinsic
#                  and no calldata, because that is what an aggregator pays inside price().
#
EOF
  echo "$raw" | grep 'ENG-3924 gas:' | sed 's/^[[:space:]]*//'
} > "$REPORT"

# Rebuild the markdown table from the report, so the doc cannot drift from the measurement.
python3 - "$REPORT" "$DOC" <<'PY'
import re
import sys

report, doc = sys.argv[1], sys.argv[2]
rows = []
for line in open(report, encoding='utf-8'):
    match = re.match(r'ENG-3924 gas:\s*(.+?)\s*=\s*(\d+)\s*$', line.strip())
    if match:
        rows.append((match.group(1), int(match.group(2))))
if not rows:
    sys.exit('no ENG-3924 gas rows found in ' + report)

table = ['| Scenario | Whole-transaction gas |', '| -- | -- |']
for label, gas in rows:
    table.append('| `{}` | {:,} |'.format(label, gas))
block = '<!-- GENERATED:gas do not edit by hand; bench-reports/eng3924-regenerate.sh rewrites this -->\n\n' \
    + '\n'.join(table) + '\n\n<!-- /GENERATED:gas -->'

text = open(doc, encoding='utf-8').read()
pattern = re.compile(r'<!-- GENERATED:gas.*?<!-- /GENERATED:gas -->', re.DOTALL)
if not pattern.search(text):
    sys.exit('no GENERATED:gas block in ' + doc)
open(doc, 'w', encoding='utf-8').write(pattern.sub(lambda _: block, text))
print('rewrote the gas table in ' + doc + ' from ' + report)

# The prose below the table cites two of its cells to make an argument about pass mark C.
# Prose cannot be regenerated, so it is checked instead: a drift fails the run rather than
# shipping a stale figure, which is the ENG-3922 review defect this whole script exists to stop.
cells = dict(rows)
cited = {
    'cycle projection, fresh rows, per fact (one tx per fact)': '**156,812 gas per fact**',
    'cycle projection, 1,000 tokens x 3 oracle sources = 3,000 facts': '**470,436,000 gas**',
}
body = open(doc, encoding='utf-8').read()
for label, phrase in cited.items():
    if label not in cells:
        sys.exit('cited row missing from the report: ' + label)
    if phrase not in body:
        sys.exit('prose cites a figure that is no longer in the doc: ' + phrase)
    if '{:,}'.format(cells[label]) not in phrase:
        sys.exit('PROSE DRIFT: "{}" is now {:,}; update the sentence citing {}'.format(
            label, cells[label], phrase))
print('prose cross-check: {} cited figures match the regenerated table'.format(len(cited)))
PY
