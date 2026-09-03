# ENG-3922 bullet 5 — what the custom store guards today, and what survives a move to EAS

The quiet risk in the adoption survey: every write-time defence `FabricaAttributeOracle` enforces
today has **no EAS equivalent**. `attest()` is permissionless and validates nothing about the
payload. Each guard therefore has to be rebuilt somewhere else, or consciously dropped. This is the
explicit list ENG-3924 consumes.

Read against the deployed store (commit `062f049`, live at
`0xFfA7535eF090C9193f44399843a05b60808ffC0D`), not against `main` — the two have diverged since the
round-1 deploy.

## The guards, and where each one lands

| # | Guard today | Where in the deployed store | On EAS | Where it has to go |
| -- | -- | -- | -- | -- |
| 1 | Provenance signer must equal `msg.sender` | `writePrice`, `ProvenanceSignerMismatch` | **Free.** `attester` IS `msg.sender`, set by EAS core | Nowhere — EAS is strictly better here |
| 2 | Write time is trusted wall-clock, not publisher-controlled | `_storeCurrentPrice` sets `lastWrittenAt` | **Free.** `Attestation.time` is block time | Nowhere |
| 3 | `valuedAt` may not be in the future | `_validatePriceWrite`, `InvalidValuedAt` | **Gone.** A `valuedAt` inside schema data is unchecked bytes | Aggregator, read time — or drop it and use `Attestation.time` only |
| 4 | Price may not be zero | `InvalidPrice` | **Gone** | Aggregator (the harness already treats zero as absent) |
| 5 | Cycle must be at or above the writer's minimum valid cycle | `_requireValidCycle` | **Gone.** EAS has no cycle concept at all | Requires a `uint64 cycle` added to the price schema — see below |
| 6 | Cycle monotonicity per row | `CycleNotMonotonic` | **Gone** | Only checkable at read time by walking `refUID`, which costs a hop per comparison. Realistically dropped |
| 7 | Minimum write interval | `minWriteInterval`, `WriteTooSoon` | **Gone** | **Not rebuildable at read time.** A rate limit is a property of writes, and a reader cannot un-write. Dropped |
| 8 | First-price cap | `maxFirstPriceUsdc6`, `FirstPriceTooHigh` | **Gone** | Aggregator, read time, as a sanity bound. Not in the aggregator today |
| 9 | Global value ceiling | `valueCeilingUsdc6`, `AboveValueCeiling` | **Gone** | Aggregator, read time. Not in the aggregator today |
| 10 | Price band, +15% / −50% | `_enforceBand`, `BandExceeded` | **Gone** | Partly covered by the aggregator's existing `maxJumpBps` breaker — but see the semantic change below |
| 11 | Per-token `register` gate | `_requireRegistered` | Gone | **Retired by decision**, not lost: round-2 Part A item 2, "there is no registry of tokens" |
| 12 | Owner's source enable | `sourceEnabled` | Gone | **Retired by decision**: round-2 position 2, no privileged roles |
| 13 | History ring for the seasoning walk | `_pushHistory`, 48 slots | Replaced by `refUID` chaining | Works, at roughly 46,700 gas per hop per oracle source against 23,500 on a custom store |

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
