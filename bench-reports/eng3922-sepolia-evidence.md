# ENG-3922 — as-shipped Sepolia evidence

Real transactions, real EAS v0.26, real reads. Every number below has a Sepolia transaction hash
behind it. No round-1 contract was modified or redeployed. Writers are lane-local throwaway EOAs,
deliberately not the shared deployer `0xBF03076547a99857b796717faF4034dea94569dF`, so nothing here
contended for a nonce with the ENG-3895 cycle-close cron.

## Deployed for the experiment

| What | Address |
| -- | -- |
| `FactPointer` (arm 2, ownerless) | `0x00aca67A7C41a237B5E7c00b0cD07DB1D94D4492` |
| `OwnerlessFactStore` (arm 3) | `0x7D826a483d76898C312cDA8E9119833ACf3C2E12` |
| `PriceGasProbe` | `0x2214F4cdA455744503988D13bCec78446cFBD71B` |
| `ArmEasPointer` | `0xcA40c79ff40B1f4792bA53517dE3159D1bF3cE5B` |
| `ArmEasIndexer` | `0x8817671856878A8C9bf95FE5B7250B7fc0A38364` |
| `ArmEasContext` (Option C) | `0xfb3a59f0Ca20c1B9e9de1DF7E0a2e3A7ADdaDd82` |
| `ArmOwnerlessStore` | `0x4844A460491034d33D78B454e6a81f9025Ca40d4` |

**This is the third deployment.** Each redeploy followed a fix to the measured read path, because functional verification has to
verify the code being shipped, and superseded deployments simply stay on chain. Deployment 2 followed
the temporal floor re-running the whole liveness evaluation per oracle source. Deployment 3 follows
CodeRabbit's finding that the EAS arms re-resolved and re-read the SAME head attestation three times
per source — once in `_current`, once for the breaker's `_previous`, once for the seasoning walk —
where the store arms read a packed struct twice. That was a real bias against EAS in every published
figure, and correcting it took the EAS arms down 18–22% against 6–8% for the store arms.

EAS schemas registered on the Sepolia `SchemaRegistry` (`resolver = address(0)`, `revocable = true`):

| Schema | uid |
| -- | -- |
| price `(uint256 tokenId, uint8 sourceId, uint128 priceUsdc6, uint24 confidence, uint64 cycle, bytes32 inputsHash)` | `0xa7dac77e6aebee43580b6591121858b006d7df052186ef5b1a59616a95920de1` |
| cycle close `(address writer, uint64 cycle, bytes32 root)` | `0x1d9dc9a79ee5a4a6af1628955732581659e70bedded150f3598d4c85e1399546` |
| coverage `(uint256 tokenId, uint64 cycle)` | `0xbe99a036dea734761bae3021a4a68f3efee8715bf3b2502daec77d2c1f9e66a5` |

Oracle-source writers: `0x889A1330555C52062d275365C5cc65b723856F9c`,
`0xB772e5a59616c047081f3C4E44c9C530b2f02cE4`, `0x366F9e43BC0d26152aDa8112EaDB087051bcD7aF`.

## The read — `price()` for a three-source read, from a real transaction

`price()` is a view, so an `eth_call` costs nothing observable. `PriceGasProbe` performs the read
inside a transaction and emits what it consumed, so these are receipts, not estimates. One token,
quantity 1, walk depth 0, round-2 configuration (no on-chain coverage check).

| Arm | `price()` gas | Whole tx | Price returned | Transaction |
| -- | -- | -- | -- | -- |
| arm 3 — ownerless custom store | **105,591** | 131,590 | 100500000000 | `0xfdfbed934c8f9d520914b1086230b6dbfac8d7f072d89edc4f1cb38f86121dfd` |
| arm 1C — all-EAS via `oracleContext` | **201,606** | 231,365 | 100500000000 | `0xec047aff0b6018e7ac9d6d0706b70914c8b1f7cabae44cadd5b839453ea3990f` |
| arm 2 — EAS plus pointer | **222,051** | 248,050 | 100500000000 | `0xc483756a4f39162a42171a90e8122aaa08ac92c4ced59ec6eccf207adf702602` |
| arm 1 — all-EAS via EAS `Indexer` | **266,120** | 292,119 | 100500000000 | `0x1cf3a43422292a479ed5bcc91f332512a7c0468744bffcbdf00f88a836abd81c` |

All four arms return the same usable price, which is the point: the arms differ only in where the
facts live.

**Sepolia against the fork, same code, two independent methods:**

<!-- GENERATED:fork-vs-sepolia do not edit by hand; bench-reports/regenerate.sh rewrites this -->

| Arm | Fork | Sepolia | Difference |
| -- | -- | -- | -- |
| arm 3 ownerless store | 106,607 | 105,591 | −1.0% |
| arm 1C `oracleContext` | 200,730 | 201,606 | +0.4% |
| arm 2 EAS plus pointer | 220,635 | 222,051 | +0.6% |
| arm 1 all-EAS `Indexer` | 251,788 | 266,120 | **+5.7%** |

Three arms agree to within 1.0%. **Arm 1's +5.7% is not noise, and chasing it produced a finding** — see below. The price rows on this deployment are fresh at depth 1, but the writers' CYCLE-CLOSE rows had reached depth 3, one per deployment, because that row is keyed by the writer rather than by the token. Like for like, the fork at cycle-close row depth 3 (270,376) against Sepolia at cycle-close row depth 3 (266,120) is -1.6%, in line with every other arm.

<!-- /GENERATED:fork-vs-sepolia -->

Both Sepolia runs published the same twenty token ids from the same three writers, so each
`(schema, attester, recipient)` row in EAS's `Indexer` holds **two** attestations where the pinned
fork holds one — confirmed on chain, `getSchemaAttesterRecipientAttestationUIDCount` returns 2 for
all three writers on the probed token.
Arm 1 is the only arm whose read touches that array, so it is the only arm whose read cost grows

with how many attestations have accumulated in a row. Measured directly on the fork, holding the
`refUID` chain at depth 0 and varying only the row:

<!-- GENERATED:indexer-row-depth do not edit by hand; bench-reports/regenerate.sh rewrites this -->

| Indexer row depth | arm 1 `price()` gas |
| -- | -- |
| 1 | 257,455 |
| 2 | 263,685 |
| 5 | 283,062 |

That is **6,230 gas for the first extra attestation and about 6,459 per attestation averaged over depths 2 to 5** — it is not one constant, and quoting it as a single figure understates how it grows.

<!-- /GENERATED:indexer-row-depth -->

And the row that grows fastest is not the token's. The cycle-close row is keyed by the **writer**, so
it gains an attestation every cycle regardless of how many tokens exist, and arm 1 reads it on every
`price()` for every token:

<!-- GENERATED:close-row-depth do not edit by hand; bench-reports/regenerate.sh rewrites this -->

| Cycle-close row depth | arm 1 `price()` gas |
| -- | -- |
| 1 | 257,455 |
| 3 | 270,376 |
| 7 | 296,212 |

About **6,459 gas per extra cycle close**. This row is keyed by the WRITER, not by the token, so it grows once per cycle for the writer and every `price()` for every token reads it. At a daily cycle close that is 365 attestations a year on one row, or roughly **2,357,535 gas added to every read** after twelve months.

<!-- /GENERATED:close-row-depth -->

The arm-1 figures here are **post-guard**. `ArmEasIndexer.recipientForToken` rejects a token id wider
than `uint160` rather than silently truncating it into a colliding Indexer row, and that check costs
**621 gas on every arm-1 read** (828 on the coverage-stamp row, which performs the lookup twice). No
other arm moves. It is the right trade — a reverting read beats a valid fact silently vanishing
because another token shared its row — but the number to quote for arm 1 is the one that includes it.

This matters beyond reconciling two numbers: **arm 1's read is the only one that is not O(1) in its
own write history.** Nothing prunes an Indexer row, so an all-EAS deployment's read cost rises every
cycle for as long as it runs. A year of weekly cycles is 52 attestations in each row.

## Against the pre-registered pass mark

The marks below were written into ENG-3922 **before any arm was built**, on Fede's bias concern, and
were never moved. Corrections to the measurements were posted four times, each before
acknowledgement; the bar itself is unchanged.

* **A, the go/no-go.** All-EAS three-source `price()` within **1.5x** the custom store's, at the same
  seasoning walk depth.
* **B, absolute.** Three-source `price()` **at most 350,000 gas** at the operating point.
* **C, write side.** One weekly cycle at 1,000 tokens — 3,000 facts, unbatched, whole-transaction
  gas — **at most 450,000,000**. A regression tripwire, explicitly not the decision.

<!-- GENERATED:pass-mark-scorecard do not edit by hand; bench-reports/regenerate.sh rewrites this -->

| Arm | `price()` at depth 0 | vs custom store | A: within 1.5x | B: <= 350,000 | per weekly cycle | C: <= 450M |
| -- | -- | -- | -- | -- | -- | -- |
| arm 3 ownerless custom store | 106,607 | 1.00x | n/a (reference) | pass | 225M | pass |
| calibration round-1 store | 111,207 | 1.04x | n/a (reference) | pass | — | read-side reference only |
| arm 1C all-EAS `oracleContext` | 200,730 | 1.88x | **FAIL** | pass | 840M | **FAIL** |
| arm 2 EAS plus pointer | 220,635 | 2.07x | **FAIL** | pass | 922M | **FAIL** |
| arm 1 all-EAS `Indexer` | 251,788 | 2.36x | **FAIL** | pass | 1,366M | **FAIL** |

Denominators: `x custom store` is against arm 3, the ownerless store; against the calibration arm (111,207) the EAS arms are 1.81x, 1.98x, 2.26x. A fails against either.

**Every EAS arm fails pass-mark A**, at 1.88x to 2.36x against a 1.5x ceiling. **B passes on every arm** and therefore separates nothing. **C fails on all three EAS arms** and passes on the ownerless store, which comes in at 225M against the 450M budget.

**Recommendation: round 2's fact store should be the ownerless custom store, not EAS.** The pre-registered go/no-go was read gas inside `price()`, and it is failed by every EAS arm even after a correction that ran in EAS's favour. The write side is worse. What EAS was going to buy — audited deployed code, nothing of ours to maintain, the writer lock for free — is real, and the honest price of declining it is roughly 190 lines needing review and audit; but the lock is three lines of that, the keying gap forced a satellite contract onto the EAS path anyway, and arm 1 — the only variant owning nothing at all — both needs an indexer that does not exist on mainnet and gets monotonically slower for as long as it runs. Keep the EAS work rather than discarding it: the schemas, adapters and harness are in this PR, and if read gas ever stops being the binding constraint this reruns in an afternoon.

<!-- /GENERATED:pass-mark-scorecard -->

## The write — one real cycle, 20 tokens x 3 oracle sources

Whole-transaction `gasUsed` from receipts.

| Operation | Total | Per token | Transaction (writer 1 of 3) |
| -- | -- | -- | -- |
| EAS `multiAttest`, 20 prices | 5,600,933 | 280,046 | `0x67362c58988e3dc8647b599f741bf894ffaa9ea08d7ea567c0d5485e8eb4c349` |
| EAS `indexAttestations`, 20 | 3,505,056 | 175,252 | `0x7b0412d2738ec5179c8f49e025c89ed698409c270ab160e46d1ed477995ea1e7` |
| pointer `pointBatch`, 20 | 546,477 | 27,323 | `0xf4e1988ac84f604cae63059da3203d4032159223c5b17ce579df8bb188d1a510` |
| ownerless store `writePriceBatch`, 20 | 1,498,996 | 74,949 | `0x9b01c63af81c2d24dddd8d0a7674c39aab8c3042192c7139efe88d4d570ee4a6` |
| EAS cycle-close `attest` | 230,461 | — | `0xf304061f284a51462de23b7d752fe484df38ca9e6873ea4868d4611858abb501` |
| EAS `indexAttestation` (cycle close) | 182,751 | — | `0xe3ccf599ec55eead3a8d1524283d574b761c33125eca4d4c03ff9e2a399459a7` |
| ownerless store `heartbeat` (cycle close) | 33,289 | — | `0x6c8afa3f45e63179167ce252b861cbc27337d17930eb179d21c26581c50ccbf1` |

The two indexing figures are **lower** than the first run's (176,107 and 234,039 per token) because
the second run appends to Indexer rows that already exist: the array slot goes non-zero to non-zero
rather than zero to non-zero. That is the write-side mirror of the read-side row-depth effect above —
indexing gets cheaper as a row deepens while reading gets dearer. The first run's figures are the
honest ones for a cold start and are the ones used below.

**Per fact, and per weekly cycle at 1,000 tokens (3,000 facts):**

| Arm | Per fact | Weekly cycle |
| -- | -- | -- |
| arm 3 — ownerless custom store | 74,949 | **225M** |
| arm 2 — EAS plus pointer (`attest` + `point`) | 307,369 | **922M** |
| arm 1 — all-EAS (`attest` + `indexAttestation`) | 455,298 | **1,366M** |

## The lock, end to end

Token `0xf1de9251b4dd69eadbda0acc7b63e058ea5fe3b4d8378016e4a2442cf7684777`. Re-run against the
second deployment; hashes below are from that run.

After ONE writer locks:

EAS revocation `0x21a2aa80f7944ae58418b1d8d520533418596883b7f2e9566324e59e32413aac` (80,192 gas),
store `setLock` `0x26052c8ff434adeba0335aed4fe8fa016fe692ddabd2885ec6e98ae96dc57e13` (46,141 gas):

```text
ArmOwnerlessStore -> true 0x0000...0000 100500000000 0
ArmEasPointer     -> true 0x0000...0000 100500000000 0
```

Still priced. **With three oracle sources and `minLiveSources` 2, one lock drops the live count to
the floor, not below it.** The ticket's bullet 3 expects one lock to trip `CHECK_MIN_SOURCES`; that
holds only when two sources were live to begin with.

After a SECOND writer locks — `0xa0408d2cf4e6a50aeddaa5943c8e81f8556892b06f087c5f945981c114414cb5`
and `0x4e6ea60b5d4b8a75beda9e0504343427559d73e15f2fb8533a364b8af0dca60e`:

```text
ArmOwnerlessStore -> false 0x4a2b6d9997de3b0ab1f2bae95dc15d063d26988a0c51617a58e74911251792fc 0 0
ArmEasPointer     -> false 0x4a2b6d9997de3b0ab1f2bae95dc15d063d26988a0c51617a58e74911251792fc 0 0
```

Note which check id that is. Round 2 of review found `CHECK_LOCK` and `CHECK_CYCLE` were declared but
never returned, so a lock was misreported as `CHECK_MIN_SOURCES`; `_liveFact` now returns the rule
that rejected each source. The value above is still `CHECK_MIN_SOURCES`
(`0x4a2b6d99…`), and correctly so: with two of three writers locked, one source remains live and the
read fails the two-source floor rather than the lock. `CHECK_LOCK` is
`0x6168652c307c1e813ca11cfb3a601f1cf3b22452021a5052d8b05f1f1f8a3e92` and is what a read returns when
EVERY source is locked.

Both check ids were read off the deployed arm rather than assumed. `price()` itself reverts,
captured through the probe in `0x15d28b8b60d030dfd48fbfcfbe06796d12688d61cd8bbd13bfa6bca9b52d52e0`, whose `PriceReverted` event carries reason `0x4c73a6a1…` =
`CheckFailed(bytes32)`.

Revocation costs 80,192 gas on EAS; the store's `setLock` costs 46,141.

## The keying gap is closed

Writer 2 attempted to write the same `(tokenId, kind)` row and moved only its own (`0xc7ca343fac2ed07b4d248e005d494f8e891d1eab54a15495e0064405ee23d208`):

```text
writer0 row before: 0x25b7b81ff5b1929a2daeeed06c842a8c9a8a9bd33fcd83b69b6da272ccad1488
writer0 row after:  0x25b7b81ff5b1929a2daeeed06c842a8c9a8a9bd33fcd83b69b6da272ccad1488
writer1 row after:  0x1111111111111111111111111111111111111111111111111111111111111111
```

## One fidelity caveat on the recorded write costs

Both Sepolia runs used synthetic token ids derived as a full `uint256(keccak256(...))`. Real Fabrica
ids are narrower: `FabricaToken` computes `uint64 smallId = uint64(keccak256(...))` and returns it
widened (`FabricaToken.sol:363-365`), so every production id is below 2^64. Round 3 of review
surfaced this while adding a bounds guard to the EAS `recipient` truncation, and the harness now
generates Fabrica-shaped ids throughout.

It matters only for calldata, and it matters in the safe direction: EIP-2028 charges 4 gas for a
zero byte against 16 for a non-zero one, and a `uint64` id carries 24 zero bytes in its word where a
256-bit id carries almost none. So **the write costs recorded above are slightly HIGH** relative to
what production would pay. Measured on the fork, the same operations with Fabrica-shaped ids:

| Operation | 256-bit ids | Fabrica-shaped ids | Difference |
| -- | -- | -- | -- |
| pointer `pointBatch` n=100, per item | 27,016 | 26,728 | −288 |
| ownerless `writePriceBatch` n=100, per item | 72,794 | 72,507 | −287 |
| EAS `multiAttest` n=100, per item | 260,123 | 259,692 | −431 |

About 288 gas per token id in calldata, roughly 0.4% of a store write and 0.2% of an attestation, and
it lands on every arm in proportion, so no comparison between arms moves. Execution gas is
unaffected — one word is one word. The on-chain figures are kept as recorded rather than re-run,
because they are real receipts and the direction and size of the bias are now measured.

## Faucet ETH

The second run re-funded the three lane-local writers with 0.12 SepoliaETH each and returned the
remainders to `0xBF03076547a99857b796717faF4034dea94569dF`, outside the keeper cadence windows:

| From | Returned | Transaction |
| -- | -- | -- |
| `0x889A1330555C52062d275365C5cc65b723856F9c` | 0.095592428842528491 | `0xe8024f258ba016c207698329939e951f21afb89656f97be889baf5a375c0891a` |
| `0xB772e5a59616c047081f3C4E44c9C530b2f02cE4` | 0.107396625192303466 | `0x48e3e7af6b2d68b88c22cfe89083e4a03b19c14cfd80322f7b71a69ccdbf7588` |
| `0x366F9e43BC0d26152aDa8112EaDB087051bcD7aF` | 0.108004640512428136 | `0x626dd97030a65c98ecaec6acbc7e28c7b028f487878d98a14befec7543337aa6` |

Both runs together cost about 0.15 SepoliaETH net. The deployer was never swept.

## Why the `broadcast/` artifacts are not committed

`forge script` wrote five run JSON files (two of them `run-latest.json` duplicates of a timestamped
sibling) totalling about 6,400 lines. They are deliberately NOT part of this branch. Everything they
would prove is already here in a more useful form: every transaction is cited by hash above, and a
hash resolves against the chain, which a committed JSON blob does not. `.worktree-init.state` is
likewise excluded, and is now in `.gitignore` so no branch picks it up again.

## Two facts about EAS's `Indexer` that the numbers depend on

1. **Indexing is not automatic.** `indexAttestation` is a separate write per attestation, measured
   at 176,107 gas per token in a 20-item batch. The all-EAS arm's per-fact write cost is `attest`
   PLUS that, which is what makes it the most expensive arm on both sides.
2. **It is not deployed on Ethereum mainnet.** The EAS repo has no `Indexer.json` under
   `deployments/mainnet/`. Whatever arm 1 measures on Sepolia cannot ship to mainnet as it stands.

## One structural cost of Option A that is not a gas number

An EAS uid is `keccak256(schema, recipient, attester, time, expirationTime, revocable, refUID,
data, bump)` — it depends on the block timestamp of the transaction that creates it. Nothing can
compute the uid it is about to create, so no publisher can attest and point at the result in one
transaction. The oracle writer must attest, read the uids back from the receipt, and point in a
second transaction. That is why the publication here runs in two phases, and it is a property of
the design rather than of this harness.
