#!/usr/bin/env bash
# ENG-3922 — regenerate every measured artifact from one command.
#
# Round 3 of review found the per-hop table in eng3922-write-time-guards.md still carrying
# pre-fix numbers: it was DERIVED from the arms report but TYPED by hand, so regenerating the
# report left it behind. Anything derived from a report is now emitted by this script, so a
# report regeneration rewrites it and the two cannot drift apart again.
#
#   usage:  SEPOLIA_RPC_URL=... bench-reports/regenerate.sh
#
# Do NOT add --gas-report. Its inspector perturbs in-test gasleft() deltas by a constant +2,500
# on every read row and +21,344 to +24,056 on the write rows; generating a report under it is
# the defect round 1 of review caught.
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE_CMD='forge test --match-path "test/bench/Eng3922Baseline.t.sol" -vv'
ARMS_CMD='forge test --match-path "test/bench/Eng3922*.t.sol" --no-match-path "test/bench/Eng3922Baseline.t.sol" -vv'
FORGE_VERSION="$(forge --version | head -1)"
FORGE_COMMIT="$(forge --version | grep -i 'Commit SHA' | awk '{print $3}')"

header() {
  cat <<EOF
# $1
#
# PROVENANCE
#   forge          : $FORGE_VERSION
#   forge commit   : $FORGE_COMMIT
#   profile        : default (foundry.toml: optimizer=true, optimizer_runs=1, via_ir=false)
#   command        : $2
#   regenerate all : bench-reports/regenerate.sh
#   fork           : Sepolia via the \`sepolia\` rpc alias, pinned FORK_BLOCK = 11_628_000
#   live fact store: 0xFfA7535eF090C9193f44399843a05b60808ffC0D (round-1, read as deployed)
#   code           : the test sources committed alongside this report
#   branch         : sebadas/eng-3922-fact-layer-bench
#
# NOTE ON --gas-report: do NOT regenerate this file with --gas-report. See the script header.
#
EOF
}

echo "[1/3] baseline"
header "ENG-3922 baseline: three-source price() on the live Sepolia round-1 fact store" "$BASELINE_CMD" \
  > bench-reports/eng3922-baseline.txt
eval "$BASELINE_CMD" 2>&1 | sed -n '/Ran .* test/,$p' >> bench-reports/eng3922-baseline.txt

echo "[2/3] arms"
header "ENG-3922 arms: five fact-layer arms, coverage rules, the write side, and Indexer row depth" "$ARMS_CMD" \
  > bench-reports/eng3922-arms.txt
eval "$ARMS_CMD" 2>&1 | sed -n '/Ran .* test/,$p' >> bench-reports/eng3922-arms.txt

echo "[3/3] derived tables"
python3 bench-reports/derive.py
echo "done"
