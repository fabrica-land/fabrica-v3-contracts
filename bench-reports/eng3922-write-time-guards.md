# ENG-3922 bullet 5 — what the custom store guards today, and what survives a move to EAS

The quiet risk in the adoption survey: every write-time defence `FabricaAttributeOracle` enforces
today has **no EAS equivalent**. `attest()` is permissionless and validates nothing about the
payload. Each guard therefore has to be rebuilt somewhere else, or consciously dropped. This is the
explicit list ENG-3924 consumes.

Read against the deployed store (commit `062f049`, live at
`0xFfA7535eF090C9193f44399843a05b60808ffC0D`), not against `main` — the two have diverged since the
round-1 deploy. Every line number below is from `git show 062f049:src/FabricaAttributeOracle.sol`
(719 lines). Note that at `062f049` there is no `_validatePriceWrite` and no `_storeCurrentPrice`:
the whole write path is inline in `_writePrice` (line 566). Both helpers were introduced by the
ENG-3523 refactor that landed AFTER the round-1 deploy, which is the divergence this preamble
warns about — and citing them here in round 1 of review was exactly the mistake the preamble exists
to prevent. Corrected.

## The guards, and where each one lands

| # | Guard today | Where in the deployed store | On EAS | Where it has to go |
| -- | -- | -- | -- | -- |
| 1 | Provenance signer must equal `msg.sender` | `writePrice` L373, revert L376 | **Free.** `attester` IS `msg.sender`, set by EAS core | Nowhere — EAS is strictly better here |
| 2 | Write time is trusted wall-clock, not publisher-controlled | `_writePrice` L610 sets `lastWrittenAt = nowTs` | **Free.** `Attestation.time` is block time | Nowhere |
| 3 | `valuedAt` may not be in the future | `_writePrice` L573, `InvalidValuedAt` | **Gone.** A `valuedAt` inside schema data is unchecked bytes | Aggregator, read time — or drop it and use `Attestation.time` only |
| 4 | Price may not be zero | `_writePrice` L569, `InvalidPrice` | **Gone** | Aggregator (the harness already treats zero as absent) |
| 5 | Cycle must be at or above the writer's minimum valid cycle | `_writePrice` L570 -> `_requireValidCycle` L663 | **Gone.** EAS has no cycle concept at all | Requires a `uint64 cycle` added to the price schema — see below |
| 6 | Cycle monotonicity per row | `_writePrice` L582, `CycleNotMonotonic` | **Gone** | Only checkable at read time by walking `refUID`, which costs a hop per comparison. Realistically dropped |
| 7 | Minimum write interval | `_writePrice` L584-586, `WriteTooSoon` | **Gone** | **Not rebuildable at read time.** A rate limit is a property of writes, and a reader cannot un-write. Dropped |
| 8 | First-price cap | `_writePrice` L578, `FirstPriceTooHigh` | **Gone** | Aggregator, read time, as a sanity bound. Not in the aggregator today |
| 9 | Global value ceiling | `_writePrice` L592, `AboveValueCeiling` | **Gone** | Aggregator, read time. Not in the aggregator today |
| 10 | Price band, +15% / −50% | `_writePrice` L589 -> `_enforceBand` L685, `BandExceeded` L690 | **Gone** | Partly covered by the aggregator's existing `maxJumpBps` breaker — but see the semantic change below |
| 11 | Per-token `register` gate | `_writePrice` L568 -> `_requireRegistered` L657 | Gone | **Retired by decision**, not lost: round-2 Part A item 2, "there is no registry of tokens" |
| 12 | Owner's source enable | `_writePrice` L567, mapping L220 | Gone | **Retired by decision**: round-2 position 2, no privileged roles |
| 13 | History ring for the seasoning walk | `_pushHistory` L678, 48 slots | Replaced by `refUID` chaining | Works, but see the per-hop costs below |

### Seasoning walk cost per hop, from the arms report

Guard 13's replacement is not a single figure and the first hop is not priced like the rest, so
here it is differenced off the rows in `bench-reports/eng3922-arms.txt` rather than asserted. Each
row is a three-oracle-source read, so a per-hop figure is the row delta divided by three times the
hops added.

**This table is generated, not typed.** `bench-reports/regenerate.sh` rewrites it from the arms
report every time the report itself is regenerated. Round 3 of review caught it carrying pre-fix
numbers precisely because it was derived by hand and so survived a regeneration of its own source.

<!-- GENERATED:seasoning-walk-per-hop do not edit by hand; bench-reports/regenerate.sh rewrites this -->

| Arm | depth 0 | depth 1 | depth 3 | depth 7 | per hop 0→1 | 1→3 | 3→7 |
| -- | -- | -- | -- | -- | -- | -- | -- |
| arm 3 ownerless custom store | 106,607 | 143,436 | 181,614 | 257,990 | 12,276 | 6,363 | 6,364 |
| calibration round-1 store | 111,207 | 158,335 | 212,423 | 320,633 | 15,709 | 9,014 | 9,017 |
| arm 1C all-EAS `oracleContext` | 200,730 | 326,271 | 529,639 | 937,229 | 41,847 | 33,894 | 33,965 |
| arm 2 EAS plus pointer | 220,635 | 346,183 | 549,539 | 957,106 | 41,849 | 33,892 | 33,963 |
| arm 1 all-EAS `Indexer` | 251,788 | 383,830 | 600,154 | 1,033,656 | 44,014 | 36,054 | 36,125 |

So the honest statement is a range, not a point: **6,363 to 15,709 gas per hop on a custom store and 33,892 to 44,014 on the EAS arms**, with the first hop dearer on every arm because it is the one that pays cold access to the history slot or the referenced attestation. A single "~46,700" figure appeared in an earlier draft of this document; it did not trace to any row, and it is withdrawn.

<!-- /GENERATED:seasoning-walk-per-hop -->

## The three that actually matter

**Guard 7, the minimum write interval, cannot be rebuilt anywhere.** A rate limit exists to stop a
write from happening. Once an attestation is on chain, no read-time rule un-writes it: the
aggregator can decline to use it, but the fact is published and any other consumer may read it. On
Sepolia today `minWriteInterval` is 0, so nothing is lost in practice right now — but the mechanism
goes away permanently, and it should go away as a decision rather than by omission.

**Guard 10, the price band, changes meaning rather than moving.** Today a write outside +15%/−50%
is REJECTED: the bad price never exists. Under EAS the aggregator's rate-of-change breaker DROPS
the source at read time: the bad price exists on chain, carries the writer's signature, and is
visible to every other consumer of that schema — including ones with no aggregator at all. For a
permissionless fact layer whose whole selling point is that third parties can read it, publishing
prices you have already judged to be wrong is a real change in posture, not a gas question.

**Guard 5 forces a schema change that is not optional.** EAS has no cycle concept, so a valuation
can only name its cycle if the price schema carries one. The adoption survey's §3 shape —
`(uint256 tokenId, uint8 sourceId, uint128 priceUsdc6, uint24 confidence, bytes32 inputsHash)` — has
no cycle field and is therefore insufficient for any rule that refers to cycles. Adding
`uint64 cycle` takes the attestation payload from 160 bytes to 192, one extra word on every write on
every EAS arm. The harness measures the schema WITH the cycle field, so the EAS numbers in this
report already include that cost.

## What EAS gives back

Guards 1 and 2 are free and enforced by EAS core rather than by our code, which is strictly better
than the deployed store's own arrangement: today `writePrice` has to check that
`provenance.signer == msg.sender` because the field is caller-supplied, and under EAS there is no
such field to get wrong. Revocation is likewise attester-only and enforced in `_revoke`, which is
where round 2's writer lock comes from at no cost. Those are genuine wins and they are why the
survey's recommendation was not obviously wrong before it was measured.
