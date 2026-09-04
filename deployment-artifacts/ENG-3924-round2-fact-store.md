# ENG-3924 — round-2 permissionless fact store

Round-2 proposal Part A items 1, 3 and 4, on the branch ENG-3922's measurement selected: the
ownerless custom store, not EAS. Contract: `src/FabricaFactStore.sol`. Sepolia only.

The round-1 store `FabricaAttributeOracle` at `0xFfA7535eF090C9193f44399843a05b60808ffC0D` stays
deployed, owned and serving. Nothing here upgrades, touches or supersedes it on chain.

## What the redeploy removes

Round 1 was `Ownable2Step` with `renounceOwnership` disabled, an owner-only per-token `register`
gate before any write, a `pricePublishers` writer allowlist, a second `recoveryWriters` allowlist
for a central lock authority nobody ever held, and owner-only `setSourceEnabled`, `setKnobs`,
`setMinValidCycle` and `anchorRoot`. Round 2 has none of it.

There is deliberately **nothing in this contract annotated "Sepolia-test-only"**. Part A item 1
permits an owner and settable knobs on a Sepolia test deploy; this design uses neither, so the test
deploy and the shape Tim wants shipped are the same code. `historyDepth` is a constructor argument
and immutable; every other parameter belongs to a writer.

Facts are keyed `writer -> tokenId -> kind`. `kind` unifies round 1's two separate keyspaces
(per-source prices, per-token attributes) into one record shape. The contract does not interpret
`kind`; `KIND_PRICE` is published so consumers agree on the key, not so the store can branch on it.

## Every round-1 write-time guard, and where it now lives

**This is the ENG-3925 handoff list.** Numbering follows `bench-reports/eng3922-write-time-guards.md`,
which reads against the deployed round-1 commit `062f049` rather than `main` — the two diverged
after the round-1 deploy, and citing `main` line numbers for deployed behaviour was a defect caught
in ENG-3922's review. Losing one of these silently is the failure ENG-3924 exists to prevent.

| # | Round-1 guard | Where it lives in round 2 | Action needed on ENG-3925 |
| -- | -- | -- | -- |
| 1 | Provenance signer must equal `msg.sender` | **Store, strengthened.** Every mutating function takes `writer` as its first argument and requires `writer == msg.sender` (`NotWriter`). There is no caller-supplied signer field left to mismatch | None |
| 2 | Write time is trusted wall-clock, not publisher-controlled | **Store.** `writtenAt = block.timestamp`, never caller-supplied | None |
| 3 | `valuedAt` may not be in the future | **Store**, kept (`InvalidValuedAt`) | None |
| 4 | Price may not be zero | **Dropped at the store, moves to the aggregator.** `writtenAt` is now the presence marker, so a zero value is no longer ambiguous with an absent row, and the store does not interpret `kind` so it cannot know which kinds are prices | **Record it.** ENG-3925 must treat a zero price as absent. Its harness already does, so this is a no-op in code and a real one on paper |
| 5 | Cycle must be at or above the minimum valid cycle | **Store**, now per-writer and writer-set: `setMinValidCycle(writer, n)`, strictly increasing | None |
| 6 | Cycle monotonicity per row | **Store**, kept, per `(writer, tokenId, kind)` | None |
| 7 | Minimum write interval | **Store, as the writer's own declaration** (`declarePolicy`), enforced by the store against that writer's own writes | Worth naming: this is the one guard the EAS branch would have lost permanently — a rate limit stops a write, and no read-time rule un-writes a published attestation. **But a declaration is not a commitment:** a writer can widen its own interval, write, and restore the old value inside a single transaction, so a consumer reading only current state sees the narrow interval that was never in force for that write. See the note under this table |
| 8 | First-price cap | **Dropped at the store.** ENG-3924 names only the band and the interval as writer declarations | **Required work.** Nothing catches it today, at either layer. ENG-3925 adds a read-time sanity bound or drops it by decision |
| 9 | Global value ceiling | **Dropped at the store.** Same reasoning | **Required work.** Nothing catches it today, at either layer. Same choice as 8 |
| 10 | Price band, +15% / −50% | **Store, as the writer's own declaration** (`declarePolicy(maxUpBps, maxDownBps)`). Round-1 semantics are preserved — the out-of-band value is rejected and never exists — and only the authority moved, owner to writer | Under EAS this guard would have degraded from refusing a write to declining to read a value already published under the writer's signature for every other consumer of the schema. **Same widen-write-restore caveat as row 7** — see the note under this table. A zero baseline is deliberately unbanded (every percentage of zero is zero, which would otherwise pin the row at zero forever) |
| 11 | Per-token `register` gate | **Retired by decision** (Tim, 3 Sep: there is no registry of tokens) | None |
| 12 | Owner's source enable | **Retired by decision** (no privileged roles; the writer address *is* the oracle source) | None |
| 13 | History ring for the seasoning walk | **Store**, kept, depth 48, per `(writer, tokenId, kind)` | None. History entries drop `valuedAt`: the deployed aggregator's walk reads only value, trusted write time and cycle (`FabricaOracleAggregator.sol:406-418`) |
| 14 | `writePriceRelayed`, the EIP-712 relayed write | **Dropped.** It existed so an allowlisted publisher could have a relayer submit. With no allowlist, a relayer's write would key to the *relayer's* address, which breaks the model outright; restoring it means bringing EIP-712 back, which ENG-3924 does not scope | **Record it.** Flagged rather than silently omitted |

> **A declared limit binds a write, not a writer (rows 7 and 10).** `declarePolicy` is callable by
> the writer at any time, so a writer can widen its own band or interval, perform the write the old
> limit would have refused, and restore the previous values — all inside one transaction. Nothing in
> this contract prevents that, and nothing should: the limits are the writer's own declaration, not
> an authority over it. The consequence for **ENG-3925** is specific: a consumer that reads
> `policyOf(writer)` sees only the *current* declaration and can be shown a narrow band that was not
> in force when the value it is about to trust was written. Only the `PolicyDeclared` event log
> reveals the widening. So `policyOf` is evidence of intent, never proof about any particular
> stored value; an aggregator that wants the stronger claim must reconstruct it from the event
> stream, or not rely on it.

A second consumer-facing caveat, same audience:

> **`lastCycleClose` does not fold in the writer's floor.** `closeCycle` refuses a cycle below the
> writer's `minValidCycle` at the time of the call, but a writer can raise its floor afterwards, and
> raising the floor does not rewrite or invalidate an already-recorded close. So
> `lastCycleClose(writer).cycle` can name a cycle that `isCycleValid(writer, cycle)` now reports
> false for. **ENG-3925 must check both** — the close for liveness, `isCycleValid` for the cycle it
> names — rather than treating a recorded close as self-evidently valid.

Retired alongside their owners, with no aggregator action:

* `recoveryStatus` and the recovery-writer role — replaced by the writer lock, per the glossary.
* `registrySeasonDelay` — retired with the registry.
* `maxSilence` — an aggregator setting, per the glossary. The store publishes the cycle-close
  timestamp; the aggregator owns the threshold.

### Aggregator-owned settings this store deliberately does not hold

`Tim's numbers`, 2026-09-03 18:12Z (Fede via Tim), recorded here so they are not lost between the
two tickets. None of these is a store concern — the store keys facts by writer address and judges
nothing — but every one of them has to exist somewhere, and that somewhere is **ENG-3925**:

| Setting | Value | Where it lives |
| -- | -- | -- |
| Oracle source set | Prycd, OpenAVM, Regrid assessor — all three | Aggregator, fixed at deploy (each source is a writer address) |
| Sources required to price | **2 of 3** | Aggregator (`minLiveSources`, floor of 2 today) |
| Aggregation across valid valuations | **MIN** | Aggregator |
| Maximum silence | 3 days, with a daily cycle close | Aggregator; the store publishes `lastCycleClose().closedAt`, the aggregator owns the threshold |
| Seasoning window | 24 hours | Aggregator; the store provides the history ring the walk reads |

## Round-2 behaviour the aggregator can rely on

* **The writer lock** is per `(writer, tokenId)` and covers every kind for that writer and token.
  `setLock(writer, tokenId, bool)`; only that writer can set or clear it.
* **Immediate invalidation.** A lock, a raised floor or a newer write all take effect on the next
  read in the same block. There is no pending or delayed state anywhere in the contract.
* **`getLiveFact(writer, tokenId, kind)`** returns the fact and a `live` flag folding in presence,
  the writer's lock and the writer's floor, in one external call. ENG-3922's arm-3 adapter made
  three separate calls for the same answer; prefer this one.
* **The cycle close carries the cycle number only** (Tim, 3 Sep 18:47Z). No Merkle root, no root
  field, no coverage stamp, and round 2 has no on-chain coverage check. `lastCycleClose(writer)`
  returns `{cycle, closedAt}`.
* **A fact write does NOT close a cycle.** Round 1 refreshed the heartbeat on every price write and
  the ENG-3922 prototype copied that. A cycle close means "I have finished this cycle", and a
  writer that cannot write during cycle N without declaring N finished has no way to run a cycle.
  `closeCycle` is the only thing that writes the cycle-close record — an aggregator must not infer
  liveness from a fact's `writtenAt`.
* **Self-declared limits are not a defence against a hostile writer.** That is what the aggregator's
  trusted-writer set is for. They are a guardrail an honest writer puts on its own pipeline, and
  every change emits `PolicyDeclared`, so a widening is observable on chain.

## Measured write cost, and a correction

Generated by `bench-reports/eng3924-regenerate.sh` (which runs the bench, rewrites the table below,
and fails if any figure this prose cites has drifted). Whole-transaction: 21,000 intrinsic +
EIP-2028 calldata + execution.

<!-- GENERATED:gas do not edit by hand; bench-reports/eng3924-regenerate.sh rewrites this -->

| Scenario | Whole-transaction gas |
| -- | -- |
| `writeFact regime 1 (fresh row, no history push)` | 98,668 |
| `writeFact regime 2 (cold history slot + cold counter)` | 93,275 |
| `writeFact regime 3-48 (cold history slot, warm counter)` | 76,176 |
| `writeFact regime 49+ (ring overwrite)` | 59,105 |
| `closeCycle (first close, cold slot)` | 49,216 |
| `closeCycle (subsequent close, warm slot)` | 32,116 |
| `setLock (lock, cold slot)` | 47,109 |
| `setMinValidCycle (kills every fact below the floor)` | 46,874 |
| `getLiveFact (cold, execution only, as read inside price())` | 13,787 |
| `cycle projection, fresh rows, per fact (one tx per fact)` | 98,705 |
| `cycle projection, 1,000 tokens x 3 oracle sources = 3,000 facts` | 296,115,000 |

<!-- /GENERATED:gas -->

### The first version of this table was wrong, and real receipts are why we know

Two independent defects inflated every row of the gas table published in the first revision of this
PR. Both are fixed; both are recorded because each is a trap the next bench in this repo can fall
into.

1. **`vm.cool` cools the account as well as its storage slots.** A real transaction begins with
   `tx.to` already warm under EIP-2929 while its storage slots are cold, so cooling the account and
   not re-warming it billed a spurious cold-account access — about 2,500 gas on every row. The bench
   now re-warms the account with a `BALANCE` read, which touches no storage, before the measurement
   window opens. *(Caught in review.)*
2. **The calldata-cost helper ran inside the measurement window.** `_calldataGas(data)` shared an
   expression with the closing `gasleft()`, and Solidity does not define operand order within an
   expression, so that helper's own ~260-iteration loop was billed to the call under test. This was
   the larger error by far — roughly 58,000 of the ~61,500 gas per write. It was **not** found by
   review; it was found by comparing the bench against real Sepolia receipts, which disagreed with
   it by far more than the ~2,500 the first defect could explain.

The corrected bench now agrees with the chain. Cross-check against real Sepolia receipts:

<!-- RECEIPTS:crosscheck -->

| Scenario | Bench | Real Sepolia receipt | Delta | Transaction |
| -- | -- | -- | -- | -- |
| `writeFact`, fresh row | 98,668 | 97,703 | +965 (+1.0%) | [`0x94741402a2509d9a7ffa9c119296702f25fb3c8de3291a1ca8c5340bf571280f`](https://sepolia.etherscan.io/tx/0x94741402a2509d9a7ffa9c119296702f25fb3c8de3291a1ca8c5340bf571280f) |
| `setLock` | 47,109 | 46,539 | +570 (+1.2%) | [`0x50a0b48079dac789ea676d318b42edd6f8bc1844d8a6c26154f19ffe03a08a0b`](https://sepolia.etherscan.io/tx/0x50a0b48079dac789ea676d318b42edd6f8bc1844d8a6c26154f19ffe03a08a0b) |
| `closeCycle`, first close | 49,216 | 48,649 | +567 (+1.2%) | [`0xba6e299e1d283739118ddbe74af263087d8dafa5a26951bfe4cbe4c6ce5a6619`](https://sepolia.etherscan.io/tx/0xba6e299e1d283739118ddbe74af263087d8dafa5a26951bfe4cbe4c6ce5a6619) |

Each receipt figure is `gasUsed` from the transaction named on its row, all three against the live
store `0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd`. `bench-reports/eng3924-regenerate.sh` allow-lists
these three values as non-measurements and points here for their provenance, so the full hashes live
in committed evidence rather than abbreviated in a script comment.

<!-- /RECEIPTS:crosscheck -->

The residual is the harness's own `CALL` overhead, which the repo's gas guide says to show rather
than fold in.

### What the corrected numbers say about pass mark C

**ENG-3922's 74,949 gas per fact still does not carry over and must not be quoted for this
contract.** That figure came from a 20-token × 3-source cycle driven through the prototype's
`writePriceBatch`, where one transaction's intrinsic cost and one cycle close amortise over 60
facts. Round 2 ships **no** batch write — proposal Part A item 12 is a round-3 candidate — so a
round-2 cycle is one transaction per fact.

Measured on that basis at 60 fresh rows: **98,705 gas per fact**, projecting to **296,115,000 gas**
for a first full cycle at 1,000 tokens × 3 oracle sources, against ENG-3922's pass mark C of
450,000,000. In the steady state (regime 3–48) the same cycle is **~229M**.

**This reverses the finding published in the first revision of this document**, which claimed a
first cycle of ~470M and therefore a breach of pass mark C. That claim was an artifact of the two
measurement defects above, not a property of the contract. **Unbatched round-2 writing clears pass
mark C with room to spare**, at roughly ~296M for an all-fresh book and ~229M in steady state.

The batching argument for round 3 is correspondingly weaker than the withdrawn number made it look,
and ENG-3926 should plan against ~296M / ~229M rather than the retracted ~470M. Tim's 18:30Z rule —
that a writer should skip rewriting an unchanged valuation — remains what keeps a real cycle well
below 3,000 facts.

## Deployed addresses

Filled in by the as-shipped Sepolia run; see the PR for transaction hashes and `cast call` output.

<!-- DEPLOYMENT:sepolia -->

| Contract | Network | Address |
| -- | -- | -- |
| `FabricaFactStore` | Sepolia | [`0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd`](https://sepolia.etherscan.io/address/0xa81f30b0ec22dbe4b25239883850367edb6f3edd) |

Deployed 2026-09-04 in block **11634895**, transaction
[`0x6289dcaf…e435`](https://sepolia.etherscan.io/tx/0x6289dcaf9c73a6b4f3f4cd219551bae0f6a02898d7cfb2fde420e0593e6ee435),
**1,359,833 gas**, Etherscan-verified, `historyDepth = 48`. Deployed from a throwaway lane EOA; the
round-1 deployer key `0xBF03…69dF` was deliberately not used, because the live ENG-3895 cycle-close
runner owns that key's nonce.

`owner()` reverts on the deployed bytecode — there is no owner to call. The deployer address holds no
privilege over any writer's row, and the as-shipped run demonstrates that by having the deployer
itself play the third address that gets refused.

**Superseded:** `0x89895c2fCC975c16AeAd2e213d2076dbF0aeb8b8` (block 11634761) was the first
deployment of this contract and carried the zero-baseline band bug described under guard 10. It is
**dead and must not be used or referenced by any consumer**; it is recorded here only so the two
addresses appearing in this PR's history are not mistaken for two live stores.

Transaction hashes and `cast call` output for the verification clauses are in the PR.

<!-- /DEPLOYMENT:sepolia -->
