# Oracle gas-cost model — ENG-3913

An interactive model of what it costs to publish oracle facts on chain, with dials, at
100 / 1,000 / 100,000 tokens. Built for [ENG-3913](https://linear.app/fabrica/issue/ENG-3913)
after Fede asked on the 2026-09-02 oracle review call for a quote at those three scales and
Tim asked for "a model with some dials so that we can play with it."

Open `index.html` in a browser, or serve this directory. It is static, self-contained, and
loads nothing from the network.

## Why the page lives here and not in a hosted artifact

Tim, 2026-09-03: a claude.ai artifact's share link pins one version and cannot show the
latest. The page is committed HTML so the link is the repo and the latest version is
whatever `main` says. It sits under `bench/` rather than `docs/` because `docs/` is
gitignored in this repo (see the repo `CLAUDE.md`), so a page under `docs/` would not be
committed at all.

## Layout

| path | what it is |
|---|---|
| `index.html` | the model. **Generated — do not hand-edit.** |
| `page-template.html` | the source of `index.html`; the model logic lives here |
| `build-model-page.py` | regenerates `index.html` from the reports and `chain-data.json` |
| `collect-chain-data.py` | reads the mainnet figures from the chain |
| `chain-data.json` | those figures, each with the block and timestamp it came from |
| `reports/bench-rows.txt` | literal `forge test -vv` output: per-scenario gas |
| `reports/gas-report.txt` | literal `forge test --gas-report` output |
| `reports/deployed-vs-main.txt` | literal output of the deployed-versus-`main` comparison |
| `deployed-round1/` | the round-1 fact store source, vendored for that comparison only |
| `identify-deployed-bytecode.py` | proves which commit produced the deployed contract |
| `reports/deployed-bytecode-id.txt` | that proof's literal output |
| `reports/eng3922-arms.txt` | ENG-3922's arms report, vendored verbatim: the per-arm `price()` rows the read side renders, and the batched write rows the batch dial reads |
| `reports/eng3922-baseline.txt` | ENG-3922's baseline report, vendored verbatim: the deployed aggregator's `price()` at each walk depth |
| `reports/eng3922-sepolia-evidence.md` | ENG-3922's Sepolia evidence, vendored verbatim: the four real-transaction probe receipts and their hashes |
| `reports/eng3922-source.txt` | the provenance sidecar pinning the commit all three were vendored from |

The measurements come from `test/Eng3913OracleGasBench.t.sol` and
`test/Eng3913DeployedVsMainGas.t.sol` in this repo.

## Regenerating everything

The one command a reviewer needs, which requires no RPC and no keys:

```sh
python3 bench/oracle-gas-model/build-model-page.py --check
```

That regenerates the page from the committed template, reports and chain data and fails if
`index.html` differs, printing where. It is the reproducibility guarantee, and unlike a
commit SHA it is something a committed file can actually assert about itself — a page cannot
name the commit it lives in.

To regenerate rather than verify:

```sh
forge test --match-path test/Eng3913OracleGasBench.t.sol -vv \
  > bench/oracle-gas-model/reports/bench-rows.txt          # (re-add the header comment)
forge test --match-path test/Eng3913DeployedVsMainGas.t.sol -vv \
  > bench/oracle-gas-model/reports/deployed-vs-main.txt
MAINNET_RPC_URL=... python3 bench/oracle-gas-model/collect-chain-data.py \
  > bench/oracle-gas-model/chain-data.json
python3 bench/oracle-gas-model/build-model-page.py
```

The `forge` runs need no RPC and no keys, so a reviewer can reproduce the gas numbers from a
clean clone. Only the mainnet readings need an RPC URL, and re-running those moves the "now"
base fee and the ETH price — the historical anchors are immutable.

The three `reports/eng3922-*` files are **not** regenerated here. They are vendored verbatim from
ENG-3922's own reports at the commit named in `reports/eng3922-source.txt`, which is the commit that
merged them to `main`; ENG-3922 regenerates them with `bench-reports/regenerate.sh`. To refresh them,
copy them across from `bench-reports/` at the new commit, update the sidecar, and rebuild — the
input digest changes, which is the point.

`build-model-page.py` refuses to build if any scenario the page needs is missing from the
reports — write side or read side. A page with a hole in it is worse than no page.

## Three things to know before reading the numbers

1. **Run the bench WITHOUT `--gas-report`.** Foundry's gas-report instrumentation inflates
   the `gasleft()` deltas the bench reads. The CSV rows are only valid from a plain `-vv`
   run; the `--gas-report` artifact is kept separately as a cross-check. Of its twelve
   Min/Max cells, eleven sit exactly 115 gas above the bench; the twelfth (`writePrice`
   Max) is 127 because that cell is pinned by a `setUp` priming write rather than by a
   benched scenario — `21,000 + 2,696 + 146,053 + 115 = 169,864`.
2. **Each scenario is measured in its own test, primed in `setUp`.** Measuring several
   inside one test warms and dirties the storage slots, and EIP-2200's dirty-slot discount
   then charges ~100 gas per word instead of ~2,900. That mistake understated a wrapped-ring
   price write by a factor of 3.9 in an early draft.
3. **"First versus repeat" is four regimes.** The history ring is 48 deep, so a row does not
   reach its cheapest state until its 49th write. Nothing on the live Sepolia store has
   wrapped yet. Quoting the cheapest figure as "the" per-write cost understates the first
   year by about 25%.

## What is not here

**An estimate, anywhere.** That is the page's one standing rule and it survives ENG-3944 intact.
Every figure is a measured row from a named report at a named commit, or an arithmetic composition
of measured rows whose formula the page states next to it.

That rule used to cost something. Until [ENG-3964](https://linear.app/fabrica/issue/ENG-3964) four
terms of the round-1 running-cost model had no measured EAS row, so the page excluded them by name
and its EAS totals were floors rather than forecasts. Tim, on seeing that: *"This model is not
complete."* He was right, and the answer was to measure them, not to reword the footnote:

| term | measured by ENG-3964 |
|---|---|
| a writer's **first** cycle close | the attestation and its lookup write, both first and repeat regimes, per arm |
| **arm 2's cycle-close pointer write** | 50,137 cold / 30,525 warm — the close is no longer charged at the attestation alone |
| **attribute writes** | attest + the arm's lookup write, at every dial size, both row regimes |
| the **batch dial at 1,000** | composed from measured rows: `4 × 230 + 80` |

**The exclusion list is now empty on every dial state**, and the totals are totals. The mechanism
that renders exclusions is deliberately kept rather than deleted — the rule it enforces still
stands, and if a future dial or arm outruns the rows it fills again.

**On the batch dial at 1,000.** No single EAS attestation of 1,000 facts fits in a block. The
largest that does is **230**, located by measuring adjacent sizes — 230 fits at 59,899,669 gas
(99.83% of the 60,000,000 limit) and 231 does not at 60,161,620. So the dial-1,000 figure is
composed from measured rows: four batches of 230 plus a residual of 80, ten transactions per
thousand facts. A projection from the n=100 per-item cost put the boundary at 231; it was one out,
which is why the pair is measured rather than divided.

**And a finding that inverts the dial's premise.** Batching on EAS does not merely converge past
100 — it *reverses*. Per-item attest cost rises from 259,692 at n=100 to 260,439 at n=231, so
larger batches cost slightly more per fact, not less. The effect is measured; its cause is not
claimed.

**Round 2 is a third codebase.** These are round-1 numbers.
[ENG-3924](https://linear.app/fabrica/issue/ENG-3924) deletes the owner, the writer allowlist and
the per-token registration gate, so every registration figure here is a round-1 cost only.

## The read side

As of [ENG-3944](https://linear.app/fabrica/issue/ENG-3944) the page carries the read side —
gas inside `price()` — which per the adoption survey, not write gas, is the binding constraint on
the fact-layer choice. It is measured by [ENG-3922](https://linear.app/fabrica/issue/ENG-3922), and
this page renders it from that ticket's three reports as merged to `main` in PR #42, squash
`55058ab0`: the per-arm `price()` for a three-source read at `refUID` walk depths 0 / 1 / 3 / 7, each
against a real Sepolia transaction, the per-arm ratios against both the ownerless custom store and
the calibration arm, and arm 1's two append-only growth curves.

Two things about how it is carried:

1. **Only raw measured integers are embedded.** Every ratio, per-hop cost, percentage and projection
   is composed in the page's own JavaScript, by the method printed beside it, and appears nowhere in
   the committed HTML. Verify them by reading the rendered DOM, not by grepping `index.html`.
2. **It is not in the self-check, deliberately.** The self-check compares something the *model*
   computes against something *measured*; the read side models nothing, so every row would be a
   measurement compared with itself. The equivalent guarantee lives in the build instead:
   `build-model-page.py` hard-errors if any read row is missing, and asserts the two independent
   Foundry suites that both measure the depth-0 read (`Eng3922Read` and `Eng3922Coverage`'s
   `coverage=none` control) agree on all five arms.

**The pass mark was pre-registered on ENG-3922 on 2026-09-03, before any arm was built or measured**,
on Fede's bias concern, and was never moved. Mark A is the all-EAS three-source `price()` within
1.5x the custom store's at the same walk depth; mark B is 350,000 gas absolute at the operating
point.

It was never formally acknowledged either: it was held unpublished pending that acknowledgement,
and Tim directed publication on 2026-09-04 16:18Z — *"I want to share the full model when all the
numbers we asked for are populated"* — which supersedes the hold **without touching the bar**. Both
facts are on the page and in the results document, because a verdict published under a
pre-registered mark is only worth what its provenance is.

**The verdict itself is deliberately not written down here.** The page tallies both marks from the
measured rows on every build, so restating the outcome in this file would be a copy that can go
stale — which is the defect three review rounds on this work were spent removing. Read it off the
*Read side* panel, or from the ENG-3922 results document in Linear, which is regenerated from the
same reports.
