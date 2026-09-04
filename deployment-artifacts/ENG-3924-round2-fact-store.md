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
| 7 | Minimum write interval | **Store, as the writer's own declaration** (`declarePolicy`), enforced by the store against that writer's own writes | None. Worth naming: this is the one guard the EAS branch would have lost permanently — a rate limit stops a write, and no read-time rule un-writes a published attestation |
| 8 | First-price cap | **Dropped at the store.** ENG-3924 names only the band and the interval as writer declarations | **Required work.** Nothing catches it today, at either layer. ENG-3925 adds a read-time sanity bound or drops it by decision |
| 9 | Global value ceiling | **Dropped at the store.** Same reasoning | **Required work.** Nothing catches it today, at either layer. Same choice as 8 |
| 10 | Price band, +15% / −50% | **Store, as the writer's own declaration** (`declarePolicy(maxUpBps, maxDownBps)`). Round-1 semantics are preserved — the out-of-band value is rejected and never exists — and only the authority moved, owner to writer | None. Under EAS this guard would have degraded from refusing a write to declining to read a value already published under the writer's signature for every other consumer of the schema |
| 11 | Per-token `register` gate | **Retired by decision** (Tim, 3 Sep: there is no registry of tokens) | None |
| 12 | Owner's source enable | **Retired by decision** (no privileged roles; the writer address *is* the oracle source) | None |
| 13 | History ring for the seasoning walk | **Store**, kept, depth 48, per `(writer, tokenId, kind)` | None. History entries drop `valuedAt`: the deployed aggregator's walk reads only value, trusted write time and cycle (`FabricaOracleAggregator.sol:406-418`) |
| 14 | `writePriceRelayed`, the EIP-712 relayed write | **Dropped.** It existed so an allowlisted publisher could have a relayer submit. With no allowlist, a relayer's write would key to the *relayer's* address, which breaks the model outright; restoring it means bringing EIP-712 back, which ENG-3924 does not scope | **Record it.** Flagged rather than silently omitted |

Retired alongside their owners, with no aggregator action:

* `recoveryStatus` and the recovery-writer role — replaced by the writer lock, per the glossary.
* `registrySeasonDelay` — retired with the registry.
* `maxSilence` — an aggregator setting, per the glossary. The store publishes the cycle-close
  timestamp; the aggregator owns the threshold.

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

## Measured write cost, and a finding for ENG-3926

Generated by `forge test --match-contract Eng3924FactStoreGasTest -vv` (no `--gas-report`; the
instrumentation perturbs in-test `gasleft()`). Whole-transaction: 21,000 intrinsic + EIP-2028
calldata + execution, one scenario per test with `vm.cool` on the store immediately before the
measured call.

<!-- GENERATED:gas do not edit by hand; bench-reports/eng3924-regenerate.sh rewrites this -->

| Scenario | Whole-transaction gas |
| -- | -- |
| `closeCycle (first close, cold slot)` | 67,044 |
| `closeCycle (subsequent close, warm slot)` | 47,549 |
| `cycle projection, fresh rows, per fact (one tx per fact)` | 156,812 |
| `cycle projection, 1,000 tokens x 3 oracle sources = 3,000 facts` | 470,436,000 |
| `getLiveFact (cold, execution only, as read inside price())` | 13,855 |
| `setLock (lock, cold slot)` | 69,441 |
| `setMinValidCycle (kills every fact below the floor)` | 62,307 |
| `writeFact regime 1 (fresh row, no history push)` | 159,227 |
| `writeFact regime 2 (cold history slot + cold counter)` | 151,345 |
| `writeFact regime 3-48 (cold history slot, warm counter)` | 134,246 |
| `writeFact regime 49+ (ring overwrite)` | 117,171 |

<!-- /GENERATED:gas -->

**ENG-3922's 74,949 gas per fact does not carry over and must not be quoted for this contract.**
That figure came from a 20-token × 3-source cycle driven through the prototype's `writePriceBatch`,
where one transaction's intrinsic cost and one cycle close amortise over 60 facts. Round 2 ships no
batch write — proposal Part A item 12 is a round-3 candidate — so a round-2 cycle is one
transaction per fact.

Measured on that basis, at 60 fresh rows: **156,812 gas per fact**, projecting to **470,436,000 gas**
for a first full cycle at 1,000 tokens × 3 oracle sources. ENG-3922's pass-mark C was 450,000,000
for that cycle, so **a first cycle over a fresh book of 1,000 tokens exceeds C**, and it exceeds it
purely because round 2 ships unbatched. In the steady state (regimes 3–48) the same cycle is
~403M and clears C. Two things follow, neither of which changes ENG-3924's scope:

* Pass mark C was pre-registered as a regression tripwire and explicitly not the decision, and the
  arms it separated nothing between were compared on the same batched basis, so the branch choice
  is unaffected.
* **ENG-3926 (oracle writer) and round-3 item 12 (batch writes) should see this number.** Tim's
  18:30Z rule — a writer should skip rewriting an unchanged valuation — is what keeps a real cycle
  well under 3,000 facts, and it is doing more load-bearing work than it looks.

## Deployed addresses

Filled in by the as-shipped Sepolia run; see the PR for transaction hashes and `cast call` output.

<!-- DEPLOYMENT:sepolia -->

| Contract | Network | Address |
| -- | -- | -- |
| `FabricaFactStore` | Sepolia | [`0x89895c2fCC975c16AeAd2e213d2076dbF0aeb8b8`](https://sepolia.etherscan.io/address/0x89895c2fcc975c16aead2e213d2076dbf0aeb8b8) |

Deployed 2026-09-04 in block **11634761**, transaction
[`0x8ddf1c27…b45b2`](https://sepolia.etherscan.io/tx/0x8ddf1c2760e796803f6117b5ae2723aeb504e3558daa13a9ae44c92bc2bb45b2),
**1,356,795 gas**, Etherscan-verified, `historyDepth = 48`. Deployed from a throwaway lane EOA; the
round-1 deployer key `0xBF03…69dF` was deliberately not used, because the live ENG-3895 cycle-close
runner owns that key's nonce.

`owner()` reverts on the deployed bytecode — there is no owner to call. The deployer address holds no
privilege over any writer's row, and the as-shipped run demonstrates that by having the deployer
itself play the third address that gets refused.

Transaction hashes and `cast call` output for the four verification clauses are in the PR.

<!-- /DEPLOYMENT:sepolia -->
