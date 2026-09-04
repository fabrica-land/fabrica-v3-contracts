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

`build-model-page.py` refuses to build if any scenario the page needs is missing from the
reports. A page with a hole in it is worse than no page.

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

Read gas inside `price()`. This page prices *writing* facts. Per the adoption survey, read gas
— not write gas — is the binding constraint on the fact-layer choice, and it is
[ENG-3922](https://linear.app/fabrica/issue/ENG-3922)'s measurement; those results are held
pending Tim's acknowledgement of the pre-registered pass mark, so no read-side figure or verdict
appears on the page.

The EAS **read side and headline running cost** follow from that read gas, so they are not here
either. The EAS **write side is** here as of
[ENG-3938](https://linear.app/fabrica/issue/ENG-3938): `multiAttest`, `indexAttestations`, the
pointer write and `multiRevoke`, and the batched `writePrice` on the custom store, are measured in
ENG-3922's arms report and driven by the batch dial — each cited to that report and commit, and
labelled provisional until ENG-3922 (PR #42) merges. An estimate is still never shown: every EAS
figure on the page is a measured row, not a guess.
