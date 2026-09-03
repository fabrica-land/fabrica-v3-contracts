# ENG-3922 — as-shipped Sepolia evidence

Real transactions, real EAS v0.26, real reads. Every number below has a Sepolia transaction hash
behind it. No round-1 contract was modified or redeployed. Writers are lane-local throwaway EOAs,
deliberately not the shared deployer `0xBF03076547a99857b796717faF4034dea94569dF`, so nothing here
contended for a nonce with the ENG-3895 cycle-close cron.

## Deployed for the experiment

| What | Address |
| -- | -- |
| `FactPointer` (arm 2, ownerless) | `0xCd417b4d82eCAe1828a443595C0146B8b213c815` |
| `OwnerlessFactStore` (arm 3) | `0x39b37b1Ff9F4F5B8d28807E14f09d56acf3141af` |
| `PriceGasProbe` | `0x2327094ca69861b2F142b9E6f01e80be7A28aF38` |
| `ArmEasPointer` | `0x33FfA4E8741875CAc12C5be51fDA4f06df82678b` |
| `ArmEasIndexer` | `0x6153790d892a4E7A87bCba463942DE659c64d47E` |
| `ArmEasContext` (Option C) | `0xf8a990e3Aa42c452635504922EB72b0198AC78E1` |
| `ArmOwnerlessStore` | `0x1a478F2AB1c2569118D100405A8aEF687FB65Cb8` |

**This is the second deployment.** Round 2 of review found that the temporal floor re-ran the whole
liveness evaluation per oracle source, so every fact-layer read happened twice on any `price()` with
seasoning enabled. Fixing it moved every arm by 24–26%, which made the first deployment's evidence a
measurement of code that is no longer in this PR. The contracts were redeployed and every number
below re-taken, because functional verification has to verify the code being shipped. The first
deployment's addresses and transactions remain on chain and are simply superseded.

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
| arm 3 — ownerless custom store | **112,376** | 138,651 | 100500000000 | `0x5002ca40b79f481659cc6f8ba7b3a04e6a191900e15d47c78907d77b001c9ef4` |
| arm 1C — all-EAS via `oracleContext` | **246,436** | 276,459 | 100500000000 | `0x33c9945d911ca9c1174146c8721ef1d862f43959b0f6ae47b98be3daef178838` |
| arm 2 — EAS plus pointer | **274,724** | 301,011 | 100500000000 | `0x4e935f76c2e2863a00d22fee9bfb0b78da8015d207c49f4203fbfaa0a3474d44` |
| arm 1 — all-EAS via EAS `Indexer` | **338,281** | 364,568 | 100500000000 | `0x79d5df884347113d7a4f0d6074081c0a22f07becd82f34975500a2793922db1f` |

All four arms return the same usable price, which is the point: the arms differ only in where the
facts live.

**Sepolia against the fork, same code, two independent methods:**

<!-- GENERATED:fork-vs-sepolia do not edit by hand; bench-reports/regenerate.sh rewrites this -->

| Arm | Fork | Sepolia | Difference |
| -- | -- | -- | -- |
| arm 3 ownerless store | 113,393 | 112,376 | −0.9% |
| arm 1C `oracleContext` | 245,830 | 246,436 | +0.2% |
| arm 2 EAS plus pointer | 273,589 | 274,724 | +0.4% |
| arm 1 all-EAS `Indexer` | 323,929 | 338,281 | **+4.4%** |

Three arms agree to within 0.9%. **Arm 1's +4.4% is not noise, and chasing it produced a finding** — see below: the fork holds one attestation per Indexer row where Sepolia holds two. Like for like, the fork at row depth 2 (336,834) against Sepolia at row depth 2 (338,281) is +0.4%, in line with every other arm.

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
| 1 | 329,596 |
| 2 | 336,834 |
| 5 | 358,965 |

That is **7,238 gas for the first extra attestation and about 7,377 per attestation averaged over depths 2 to 5** — it is not one constant, and quoting it as a single figure understates how it grows.

<!-- /GENERATED:indexer-row-depth -->

The arm-1 figures here are **post-guard**. `ArmEasIndexer.recipientForToken` rejects a token id wider
than `uint160` rather than silently truncating it into a colliding Indexer row, and that check costs
**621 gas on every arm-1 read** (828 on the coverage-stamp row, which performs the lookup twice). No
other arm moves. It is the right trade — a reverting read beats a valid fact silently vanishing
because another token shared its row — but the number to quote for arm 1 is the one that includes it.

This matters beyond reconciling two numbers: **arm 1's read is the only one that is not O(1) in its
own write history.** Nothing prunes an Indexer row, so an all-EAS deployment's read cost rises every
cycle for as long as it runs. A year of weekly cycles is 52 attestations in each row.

## The write — one real cycle, 20 tokens x 3 oracle sources

Whole-transaction `gasUsed` from receipts.

| Operation | Total | Per token | Transaction (writer 1 of 3) |
| -- | -- | -- | -- |
| EAS `multiAttest`, 20 prices | 5,609,525 | 280,476 | `0x921436180f7676a8db8d800785b48d97faa57b404e849ffcddbd94350fcd4c54` |
| EAS `indexAttestations`, 20 | 3,163,032 | 158,152 | `0x39eaa8d62551fc33bc8ed822422561334df3a1fef195bd9dce5851cb8cfadd3c` |
| pointer `pointBatch`, 20 | 552,201 | 27,610 | `0x20024664d0e3a7ded9d3b7f558b8dd49a61b8e173ee974b92a8dffca3c9af839` |
| ownerless store `writePriceBatch`, 20 | 1,504,984 | 75,249 | `0xe676503c23d38d0b004ab985c29d3239f156f58b9d3faf59d76c53554ed388a2` |
| EAS cycle-close `attest` | 230,461 | — | `0xcbfb7f60c7f31f34dd3bad3f90150d6d96d749c29dc02d1c9c3af457e9b077ab` |
| pointer `point` (cycle close) | 46,988 | — | `0xe53fbaa26e649cf93667fff667588501427ae4c1d020321eb90cebb17e7f179d` |
| EAS `indexAttestation` (cycle close) | 182,739 | — | `0x23320efa257376804fe498e6648407d78c926bc66d5a6b622c8486760266e124` |
| ownerless store `heartbeat` (cycle close) | 33,289 | — | `0x201dc789d1c94f32cf81327de662ad31c6d9e611933a604209364f08d837cf0c` |

The two indexing figures are **lower** than the first run's (176,107 and 234,039 per token) because
the second run appends to Indexer rows that already exist: the array slot goes non-zero to non-zero
rather than zero to non-zero. That is the write-side mirror of the read-side row-depth effect above —
indexing gets cheaper as a row deepens while reading gets dearer. The first run's figures are the
honest ones for a cold start and are the ones used below.

**Per fact, and per weekly cycle at 1,000 tokens (3,000 facts):**

| Arm | Per fact | Weekly cycle |
| -- | -- | -- |
| arm 3 — ownerless custom store | 75,249 | **226M** |
| arm 2 — EAS plus pointer (`attest` + `point`) | 308,086 | **924M** |
| arm 1 — all-EAS (`attest` + `indexAttestation`, cold rows) | 456,583 | **1,370M** |

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
