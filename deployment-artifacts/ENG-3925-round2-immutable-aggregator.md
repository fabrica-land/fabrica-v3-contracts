# ENG-3925 — round-2 immutable aggregator and the new Sepolia oracle pool

Round-2 proposal Part A items 1 and 5, decided by Tim on 3 September 2026 17:53Z. Contract:
`src/FabricaImmutableAggregator.sol`. Deploy script: `script/FabricaImmutableAggregatorDeploy.s.sol`.
Sepolia only.

The round-1 aggregator `FabricaOracleAggregator`, the round-1 pool `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B`
and the signed-quote pool all stay deployed and serving. Nothing here upgrades, repoints or
supersedes any of them on chain: this ticket **adds** an aggregator and a pool.

The fact store this aggregator reads is the round-2 store from
[ENG-3924](https://linear.app/fabrica/issue/ENG-3924) at
[`0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd`](https://sepolia.etherscan.io/address/0xa81f30b0ec22dbe4b25239883850367edb6f3edd).
The earlier address `0x89895c2fCC975c16AeAd2e213d2076dbF0aeb8b8` is **dead** — it carried the
zero-baseline band bug — and is named here only because it still circulates in briefs.

## What the redeploy removes

Round 1's `FabricaOracleAggregator` is `Ownable2Step` with a pre-freeze owner path — `setFactStore`,
`setUsdc`, `setValidatorId`, `setSourceIds`, `setKnobs`, `setLandUsePolicy` — plus an opt-in
`renounceAggregator()` that had to be remembered. Round 2 has none of it. Every parameter is an
`immutable` written by the constructor into the deployed bytecode, and the deployed ABI contains no
state-mutating external function at all: no owner, no setter, no freeze step, nothing to renounce.
A rule change is a new aggregator and a new pool.

The trusted writer set lives in `immutable` slots rather than a constructor-written storage array.
Storage written only by a constructor would be equally unchangeable, but immutables put the
addresses in the code itself — readable from the verified source with no storage probe — and save a
cold `SLOAD` per writer inside `price()`, which sits on the pool's borrow path.

## Constructor parameters

`Tim's numbers`, 2026-09-03 18:12Z, plus the round-1 values ENG-3925 carries forward. These are the
deploy script's defaults (`FabricaImmutableAggregatorDeployScript.defaults()`), pinned by
`test_defaultsAreTimsNumbers`. Each threshold is overridable by environment so a redeploy under a
later ruling needs no code change, but an override is **bounded, not merely narrowed**: every value
is read as a `uint256` and checked against its target type before the cast
(`_bounded` / `EnvValueOutOfRange`). An out-of-range override is REFUSED rather than truncated —
`FABRICA_AGGREGATOR_MAX_JUMP_BPS=70000` would otherwise have become `4464` and
`FABRICA_AGGREGATOR_MAX_SILENCE=2**64` would have become `0`, permanently, and the
intended-vs-deployed readback could not have caught either because it compares the deployed value
against the same truncated struct. The two addresses are not overridable at all: see below.

<!-- markdownlint-disable MD013 -->

| Parameter | Value | Source |
| -- | -- | -- |
| `factStore` | `0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd` | ENG-3924, the live round-2 store; the script refuses any other (`NonCanonicalFactStore`) |
| `usdc` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | canonical Sepolia USDC; the script refuses any other |
| `writers` | the three oracle sources (Prycd, OpenAVM, Regrid assessor) | Tim's numbers; **no default in the script** |
| `minLiveSources` | 2 | Tim's numbers, 2 of 3; the contract refuses below 2 |
| `maxSilence` | 3 days (259,200 s) | Tim's numbers (Fede's number) |
| `cycleCloseInterval` | 1 day (86,400 s) | Tim's numbers; published, not checked — see below |
| `seasoningWindow` | 24 hours (86,400 s) | 2 September call |
| `maxJumpBps` | 5,000 | rate-of-change breaker, as in round 1 |
| `maxDispersionBps` | 20,000 | dispersion breaker, as in round 1 |
| `maxFirstPriceUsdc6` | 50,000,000 USDC | guard 8, round-1 store default |
| `valueCeilingUsdc6` | 50,000,000 USDC | guard 9, round-1 store default |

<!-- markdownlint-enable MD013 -->

### Both addresses are pinned, and why the fact store had to be

`SEPOLIA_USDC` and `SEPOLIA_FACT_STORE` are constants in the deploy script and are checked together
in `_validateChainCurrencyAndStore`; neither is overridable by environment. The currency pin is
inherited from the round-1 script. The fact-store pin is new in this ticket and is not a typo guard:
**this store has already been redeployed once.** The first round-2 deployment at
`0x89895c2fCC975c16AeAd2e213d2076dbF0aeb8b8` carried the zero-baseline band bug, is dead, and still
circulates in briefs.

The aggregator's constructor cannot catch that substitution. `_validateWiring` asks three questions
of the configured store — is it non-zero, does it carry code, does its `KIND_PRICE` match — and the
dead store answers all three exactly as the live one does. Read from Sepolia against both addresses:

| Store | Runtime bytes | `KIND_PRICE()` |
| -- | -- | -- |
| `0xa81f30b0…` live | 6,036 | `0x9ef8710b2d7ed0121d9ca0862acabaf24b456f4c111b9e9f438f4e4cc9e7d6d0` |
| `0x89895c2f…` dead | 6,022 | `0x9ef8710b2d7ed0121d9ca0862acabaf24b456f4c111b9e9f438f4e4cc9e7d6d0` |

The two are **not** identical — they differ in bytecode and by 14 bytes of runtime — but they are
indistinguishable *to the checks the constructor performs*, which is the property that matters. The
6,036 figure cross-checks against `forge build --sizes` for `FabricaFactStore`. (Take the byte count
from `cast code | wc -c` and you get ~12,046: that is hex CHARACTERS, about twice the byte count.)

The intended-vs-deployed readback cannot catch the substitution either, since it compares the
deployed value against the same configured address. The script is the only layer that can, and
binding a pool's price feed to the wrong store is permanent here.
`test_refusesTheSupersededRound2FactStore` etches the real store runtime at the dead address,
asserts the two are indistinguishable to those same checks, and shows the refusal.

The writer set has **no default in the deploy script**. The oracle source addresses are a Tim
decision and their provisioning is [ENG-3926](https://linear.app/fabrica/issue/ENG-3926); a guessed
address here would be immutable for the life of the contract, so the script refuses to run without
`FABRICA_AGGREGATOR_WRITERS` rather than inventing one.

### `cycleCloseInterval` is published, not checked

No branch reads it. The aggregator cannot enforce a writer's cadence — only the writer decides when
it closes a cycle — so making it a check would be theatre. It is on chain because it is the
assumption behind `maxSilence`: three days is **three** daily cycle closes, so a writer misses two
closes before its feed goes dark. `test_round2_deployedParametersAreTimsNumbers` asserts that
relationship (`maxSilence == 3 * cycleCloseInterval`) rather than the two numbers separately.

## Round-2 rules the aggregator implements

Tim, 3 September 2026 18:47Z and 18:50Z. The 18:17Z–18:44Z Merkle-root and coverage paragraphs on
ENG-3925 are history and are not implemented.

* Per trusted writer and token, the **newest unrevoked valuation** is the only one considered. The
  store supersedes by overwriting the row, so this needs no extra work at read time.
* A **lock, a revocation or a newer write invalidates prior state immediately**. The store's
  `getLiveFact` folds presence, the writer's lock and the writer's floor into one call, and nothing
  in the aggregator caches.
* The writer's **last cycle close must be within `maxSilence`**, and the cycle that close names must
  still be valid — see the caveat below.
* **Nothing per read, nothing per quote.** `oracleContext` is unused, per Tim's 18:44Z ruling that
  buy-now-pay-later calldata is fixed days before execution.
* **No root, no proof, no coverage check.** A token a writer stops covering is that writer's lock or
  revocation to send: fail-open by design this round.
* The read interface stays MetaStreet `IPriceOracle`, so the pool's upstream code is unchanged and
  no change is needed in `fabrica-land/metastreet-contracts-v2`.

### Both halves of the ENG-3924 cycle-close caveat are checked

`closeCycle` refuses a cycle below the writer's floor **at the time of the call**, but raising the
floor afterwards does not rewrite an already-recorded close. So `lastCycleClose(writer).cycle` can
name a cycle `isCycleValid(writer, cycle)` now reports false for. The aggregator checks the close
for liveness **and** `isCycleValid` for the cycle it names;
`test_silence_recordedCloseBelowTheWritersRaisedFloorIsNotLiveness` makes the trap executable.

`policyOf` is deliberately not read, and is absent from `IFabricaFactStore` entirely. Per the same
handoff, a declared limit binds a write and not a writer — a writer can widen its band, write, and
restore the old value in one transaction — so `policyOf` is evidence of intent and never proof about
a stored value. The aggregator relies on its own immutable bounds instead.

## The write-time guards ENG-3924 handed over

Numbering follows `bench-reports/eng3922-write-time-guards.md`, as carried by
`deployment-artifacts/ENG-3924-round2-fact-store.md` and Linear comment `b90c9467`.

<!-- markdownlint-disable MD013 -->

| # | Round-1 guard | Disposition on ENG-3925 |
| -- | -- | -- |
| 4 | Price may not be zero | **Re-established.** A `KIND_PRICE` fact with `value == 0` is treated as absent. The store's presence marker is `writtenAt` and it does not interpret `kind`, so this is the aggregator's to enforce (`test_guard4_zeroValuationIsAbsentNotAPriceOfZero`) |
| 8 | First-price cap | **Re-established** as an immutable read-time bound. A writer's valuation with no history for that `(writer, tokenId)` and `value > maxFirstPriceUsdc6` is dropped as not live. Exactly at the cap is kept, matching round 1, which reverted only strictly above |
| 9 | Global value ceiling | **Re-established** as an immutable read-time bound. Any valuation above `valueCeilingUsdc6` is dropped as not live |
| 14 | `writePriceRelayed` (EIP-712 relay) | **Stays dropped.** It is a store-side write path with no aggregator surface; restoring it means bringing EIP-712 back to the store, which neither ticket scopes |
| — | Land-use check (`CHECK_LAND_USE`, round-1 aggregator) | **Dropped by decision.** Land use is not in the round-2 rules, and the round-2 store's generic `kind` record has no typed attribute read to replace `getAttribute`. Recorded rather than silently omitted |
| — | `CHECK_REGISTRY`, `CHECK_RECOVERY` (round-1 aggregator) | **Retired with their subjects** — the registry (Tim: there is no registry of tokens) and the recovery writer (replaced by the writer lock) |

<!-- markdownlint-enable MD013 -->

Guards 4, 8 and 9 **drop the offending valuation** rather than reverting the whole read. That is the
only shape available to a read-time re-establishment of a write-time guard: the bad value already
exists in the store, and refusing to price a token because one of three writers published nonsense
would hand any single trusted writer a denial-of-service lever over the pool.

### One honest limitation of guards 8 and 9 at the deploy values

At the round-1 store defaults, `maxFirstPriceUsdc6` and `valueCeilingUsdc6` are the **same number**
(50,000,000 USDC). Guard 9 applies to every valuation and guard 8 only to a first valuation, so at
these values guard 9 fires first in every case guard 8 would have caught, and **guard 8 is
unobservable on the deployed configuration**. It is nonetheless implemented, separately configurable
and separately tested (`test_guard8_firstValuationAboveTheCapIsDroppedButAtTheCapIsKept` isolates it
with a cap strictly below the ceiling), so choosing a lower first-price cap is a config change and
not a code change. This is stated rather than left for a reviewer to notice: the round-1 store
carried the same coincidence, with the same consequence, behind a comment saying the ceiling was the
"same as first-price default until class ceilings are set".

## Check set and what each refusal means

`eligibilityReport(currencyToken, tokenId)` returns the first failed check without reverting;
`price()` reverts with `CheckFailed(checkId)` carrying the same id.

<!-- markdownlint-disable MD013 -->

| Check | Fires when |
| -- | -- |
| `CHECK_CURRENCY` | the currency is not the configured USDC |
| `CHECK_MAX_SILENCE` | fewer than `minLiveSources` trusted writers have a recent, still-valid cycle close — the feeds are dark |
| `CHECK_MIN_SOURCES` | enough feeds are live but fewer than `minLiveSources` usable valuations survive the filters — the token is not priceable |
| `CHECK_DISPERSION` | the live valuations disagree by more than `maxDispersionBps` |

<!-- markdownlint-enable MD013 -->

Silence is per writer in round 2, so the two liveness failures had to be separated: a lender reading
`max_silence` knows to look at the writers, and one reading `min_sources` knows to look at the
token. Round 1's single `CHECK_HEARTBEAT` could not make that distinction because the heartbeat was
per validator.

## The pool

The new pool is a `BeaconProxy` created through the live Sepolia `PoolFactory.createProxied` on the
shared pool beacon, exactly as ENG-3519's launch path specifies, with the launch duration and rate
tiers and `priceOracle` set to this aggregator.

<!-- markdownlint-disable MD013 -->

| Component | Sepolia address |
| -- | -- |
| `PoolFactory` | `0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83` |
| Pool beacon (`UpgradeableBeacon`) | `0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e` |
| Collateral token (`FabricaToken`) | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` |
| Currency token (USDC) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

<!-- markdownlint-enable MD013 -->

**No change is needed in `fabrica-land/metastreet-contracts-v2`.** Its existing
`script/FabricaLendingPoolCreateWithAggregator.s.sol` takes the oracle as
`FABRICA_LENDING_AGGREGATOR` and passes it straight into the pool's initializer as an
`IPriceOracle`; because the round-2 aggregator keeps that interface, the round-1 launch script
creates the round-2 pool unmodified. That repo therefore gets deployment artifacts only, not a
second PR.

## Verification

`test/Eng3925ImmutableAggregatorSepoliaFork.t.sol` extends `Eng3523OraclePoolSepoliaForkTest`, which
extends the ENG-3519 launch-pool harness, so one run exercises every round-1 invariant as well as
the round-2 ones against the live Sepolia fork — 23 tests, all green.

**The green `Foundry project` check on a push or PR does not execute those 23.** The CI step is
correctly gated to skip rather than silently pass when `SEPOLIA_RPC_URL` is absent, and the suite
collapses to a single skipped unit when the fork cannot be created, so 0 of 23 run there.
`FABRICA_REQUIRE_SEPOLIA_FV` — which turns a missing RPC into a loud failure — is set only on the
scheduled run. The 23/23 recorded here is a local run with the RPC configured, and that is the
evidence that carries. (The nightly on `main` is separately failing; that is ENG-4052, not this
ticket.)

`setUp` is deliberately not overridden. The round-2 fixture warps a full seasoning window, and
Foundry re-runs `setUp` for every test, so a warp there would age the inherited round-1 fixture —
its heartbeat would go stale and its seasoned observation would stop binding — and would silently
rewrite the round-1 acceptances this suite exists to keep green. The round-2 stack is built per test
by `_setUpRound2()` instead.

## Before the broadcast

The deploy is permanent: the aggregator has no owner and no setter, so a wrong parameter or a
regression that reaches Sepolia is corrected only by deploying a new aggregator and a new pool. The
green `Foundry project` check is **not** sufficient evidence to broadcast on, for the reason recorded
under Verification — on a push or PR it executes none of the 23 fork invariants.

So the fork suite is a **precondition of the broadcast**, run deliberately, not inferred from CI:

```bash
set -a; . ./.env; set +a          # SEPOLIA_RPC_URL must be set
FABRICA_REQUIRE_SEPOLIA_FV=1 \
  forge test --match-contract Eng3925ImmutableAggregatorSepoliaForkTest -vvv
```

`FABRICA_REQUIRE_SEPOLIA_FV=1` is the load-bearing half: without it a missing or broken RPC makes
the suite **skip** and report `ok`, which is indistinguishable from a pass at a glance. With it, a
missing RPC is a loud failure. Expect 23 passed / 0 failed / 0 skipped — a run reporting any skips
has not verified anything and does not authorise a broadcast. Record that run's output alongside the
deploy evidence.

This states the discipline for THIS deploy. It does not change the repo's CI gating, which is shared
with the ENG-3523 step and is ENG-4052's to settle, and it does not restate the repo's shipping
playbook (`CLAUDE.md`, step 3 fork-test before step 4 Sepolia ship), which already puts fork-testing
ahead of the deploy.

## Deployed addresses

Filled in by the as-shipped Sepolia run; see the PR for transaction hashes, the
intended-vs-deployed parameter table and `cast` output for every verification clause.

<!-- DEPLOYMENT:sepolia -->

| Contract | Network | Address |
| -- | -- | -- |
| `FabricaImmutableAggregator` | Sepolia | [`0xbDD420cB9b171e743EDb8Ad7584aF52347F6CA57`](https://sepolia.etherscan.io/address/0xbDD420cB9b171e743EDb8Ad7584aF52347F6CA57) |
| Round-2 oracle pool (`BeaconProxy`) | Sepolia | [`0xdE70d398Be943BB1CCd77a5c081e38046Ca17764`](https://sepolia.etherscan.io/address/0xdE70d398Be943BB1CCd77a5c081e38046Ca17764) |

<!-- /DEPLOYMENT:sepolia -->

Aggregator deployed 2026-09-08, transaction
[`0xb693a0fd…37b0`](https://sepolia.etherscan.io/tx/0xb693a0fd30d3ac261b1bbc92d88da455eaffc9b1340a21cf9e02f4a7fe1337b0),
Etherscan-verified, runtime **7,148 bytes**. That size agrees with `forge build --sizes`, but a size
is only a consistency check: two different contracts can share a byte count, so a length never
establishes provenance. What establishes it is byte comparison. Rebuilding this source and diffing
against `cast code 0xbDD420cB…` with the 37 immutable spans (19 slots, 1,184 bytes) masked on both
sides gives **zero differing offsets across the 7,095-byte executable region**, at an identical solc
tag (`64736f6c63430008230033`, 0.8.35), which Etherscan independently reports alongside optimizer-on
/ `runs = 1` matching `foundry.toml`. The remaining 53 bytes are the CBOR metadata trailer, whose
32-byte IPFS hash digests the compiler's *input* JSON and is therefore build-environment dependent.
It matched here because this rebuild ran on the machine that produced the deploy; **a rebuild
anywhere else will differ in exactly that span and nowhere else**, which is expected and is not
evidence of a different contract. Reproduce the executable-region result rather than the
whole-runtime one — that is the part any verifier can check, and it is the part that carries the
claim worth making: the deployed executable code IS this source's output, so the source's
properties — no owner, no setter, 23 functions all `view` — are properties of the deployed contract
rather than inferences about it. Pool created through the live `PoolFactory` in
[`0x032be2af…12d8`](https://sepolia.etherscan.io/tx/0x032be2af05e0afb735cb5d150b8a7eaf45c5cb2484407bb535e258f04deb12d8):
451-byte `BeaconProxy` on the shared beacon, `priceOracle` = the aggregator, `admin` = the factory,
`isPool` true, `IMPLEMENTATION_VERSION` 2.15.

`owner()` does not exist on the deployed bytecode, and neither does any other state-mutating
selector: the verified ABI is 23 functions, every one `view`. All fourteen constructor parameters
read back equal to the intended values. Full as-shipped evidence — every clause, with literal `cast`
output and transaction hashes — is the FV comment on
[fabrica-v3-contracts#50](https://github.com/fabrica-land/fabrica-v3-contracts/pull/50), bound to
head `9629b54f`.

The trusted writer set is three **lane-generated signer EOAs**, not the real oracle sources' keys:
`0x89C52827A397E031f902694d2d301001C7cC709d` (Prycd slot),
`0x16d37D507D684341E1b5c9fAc403CF04Ebb1886f` (OpenAVM slot),
`0xDc3B2ECe86FD99cE953BCFeB9152bfe9D950CE48` (Regrid assessor slot). Mapping those slots to the real
signers is [ENG-3926](https://linear.app/fabrica/issue/ENG-3926)'s provisioning; because the writer
set is immutable, adopting the real keys means a new aggregator and a new pool, which is the
round-2 design working as intended rather than a surprise.

**The fact store has no writer gate, so a misdirected source fails silently.** The round-2
`FabricaFactStore` is permissionless in the sense that matters here: it authorises no particular set
of writers, and there is no owner, no allowlist and no gate in front of a write. The one thing it
does reject is impersonation — every mutating entry point (`writeFact`, `closeCycle`, `setLock`,
`setMinValidCycle`, `declarePolicy`) runs `_requireWriter`, which reverts `NotWriter` unless the
`writer` argument equals `msg.sender`. It restricts what you may write *as*, not who may write, and
that restriction is load-bearing rather than pedantic: self-attribution is the whole reason an
immutable trusted-writer set is worth anything. If any address could write facts attributed to
`0x89C52827…`, the set in this aggregator's constructor would be decorative. A real oracle
source that writes from an address outside this aggregator's immutable trusted set does **not** get
an error. The write succeeds, the fact is stored and is readable by anyone; this aggregator simply
never reads it. The observable failure is a missing source, not a reverted transaction, so nothing
on the write side will ever surface the mistake — the aggregator's live-source count is where it
shows up. At the shipped 2-of-3 minimum, one misdirected writer is absorbed silently and a second
takes `price()` to `CheckFailed(CHECK_MIN_SOURCES)` and the pool with it, which is the
`0xdE70d398…` refusal recorded in the FV comment. Trusted-writer enforcement is a read-side
property of the aggregator, never a write-side check in the store.

This is also why adopting the ENG-3926 keys is a new aggregator and a new pool rather than a
re-pointing. There is no writer allowlist anywhere to update: the only way a real source's prices
reach a pool is for the aggregator's immutable constructor argument to already hold that source's
address, and that argument is fixed at deploy. Writing to the same store from the real keys against
*this* aggregator would be accepted by the store and ignored by the feed.

**Throwaway, not part of the launch:** `0xd57df0bf6e4cb03742afc5802268795dd37fd4d5` is a second
aggregator against the same store, identical in every constructor argument except `maxSilence = 1
second`, deployed only to exercise the literal timestamp branch that a 3-day threshold cannot reach
inside a session. It is wired to no pool and nothing should reference it. It is also the only deploy
recorded under `broadcast/FabricaImmutableAggregatorDeploy.s.sol/11155111/` — the shipped aggregator
was deployed through the lane's vault wallet, which produces no broadcast file, so that directory
must not be read as naming the launch contract.

That throwaway was deployed from a disposable Foundry keystore generated in-process, never written to
argv, environment, logs or output, and deleted immediately afterwards along with forge's cached
sensitive-values file. The shipped aggregator and the pool were both deployed from the lane's vault
wallet. The round-1 deployer key `0xBF03…69dF` was never used: it is the ENG-3895 cycle-close runner's
key and that runner owns its nonce.

Round-1 `FabricaOracleAggregator`, the round-1 pool `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B` and
the signed-quote pool are untouched and still serving — verified after the deploy by reading
`LIVE_POOL.priceOracle()`, which still returns `0x522C7F01B535b36eca6b27C32A65Ee79e7c4df45`.
