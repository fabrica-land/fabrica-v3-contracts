# ENG-4203 — the round-3 aggregator and its Sepolia pool

[ENG-4203](https://linear.app/fabrica/issue/ENG-4203), phase B. Sepolia only; mainnet is out of
scope and was never touched. Contract: `src/FabricaImmutableAggregator.sol`, unchanged. Deploy
script: `script/FabricaImmutableAggregatorDeploy.s.sol`, unchanged — the round-3 re-point landed in
[contracts#53](https://github.com/fabrica-land/fabrica-v3-contracts/pull/53)
(`b99d5101861fa0fdda691872aab0585fc3b6b9bb`), which is this branch's base.

**This ticket changes no contract, no script and no test.** It deploys the existing aggregator
against the round-3 fact store with one knob amended, and creates a pool pointed at it. It is the
same shape as [ENG-3926](https://linear.app/fabrica/issue/ENG-3926), one generation on.

## Why a redeploy was the only option

`FabricaImmutableAggregator` holds its fact store in an `immutable` slot and the pool reads the
aggregator, so adopting the round-3 store
[`0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D`](https://sepolia.etherscan.io/address/0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D)
means a new aggregator and a new pool. There is no setter and nothing to migrate; that is the
round-2 design working as intended, and it is the same reason ENG-3926 was a redeploy.

The knob amendment forces the same conclusion independently. `maxDispersionBps` is an `immutable`
too, so Fede's 2026-09-18 ruling could not have been applied to the ENG-3926 aggregator under any
circumstances.

Authorized by Tim on 2026-09-14 ("Round-3 stack redeploy: go ahead"). The parameter table below was
sent to Brioche and approved before any broadcast; that approval is the authorization checkpoint,
and nothing was signed before it.

## Deployed addresses

<!-- DEPLOYMENT:sepolia -->

| Contract | Network | Address |
| -- | -- | -- |
| `FabricaImmutableAggregator` (round 3) | Sepolia | [`0x54D671dCc9B00b8c4aE40a664370D515A9FC9D9E`](https://sepolia.etherscan.io/address/0x54D671dCc9B00b8c4aE40a664370D515A9FC9D9E) |
| Round-3 oracle pool (`BeaconProxy`) | Sepolia | [`0x25dF3D8C3CEBF34a6037b3183f128d8b87275abA`](https://sepolia.etherscan.io/address/0x25dF3D8C3CEBF34a6037b3183f128d8b87275abA) |

<!-- /DEPLOYMENT:sepolia -->

<!-- markdownlint-disable MD013 -->

| | Aggregator | Pool |
| -- | -- | -- |
| Transaction | [`0xae92814f…c8a8`](https://sepolia.etherscan.io/tx/0xae92814f6b7493cb88df48f25fb847fe72bf60d5e6f4ef15ab3ba86cb14fc8a8) | [`0xdb06ce93…039a`](https://sepolia.etherscan.io/tx/0xdb06ce93fa2f1f6dc2d98b7e1fc9612db02f8b78e9d3b925121718158ce2039a) |
| Status | 1 | 1 |
| Block | 11,733,836 | 11,733,842 |
| `gasUsed` | 1,653,717 | 522,200 |
| Effective gas price | 1,625,691,030 wei | 1,200,197,104 wei |

<!-- markdownlint-enable MD013 -->

The aggregator landed on `0x54D671dCc9B00b8c4aE40a664370D515A9FC9D9E`, the address
`cast compute-address --nonce 0` derived for the disposable deployer **before it was funded**. Two
independent derivations agreed ahead of signing; a mismatch was the stop condition. The pool's
`gasUsed` of 522,200 is identical to the ENG-3926 pool's — the same factory doing the same work.

The pool was created through the live `PoolFactory`, so it is an internal `CREATE` inside a `CALL`
rather than a top-level contract creation.

<!-- markdownlint-disable MD013 -->

| Component | Sepolia address |
| -- | -- |
| `PoolFactory` | `0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83` |
| Pool beacon (`UpgradeableBeacon`) | `0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e` |
| Beacon `implementation()` | `0x78F794373E7B4b2fCF86987C70abdA0e12fE9BB5` |
| Collateral token (`FabricaToken`) | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` |
| Currency token (USDC) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

<!-- markdownlint-enable MD013 -->

## Constructor parameters

**Nine of the eleven** are the ENG-3926 aggregator's values, **read back from `0x1b17C9b2…` on
chain before this deploy, never copied from that record**. **Two differ:** `factStore`, which is the
whole point of the redeploy, and `maxDispersionBps`, which is Fede's amendment. Each has its own
independent reason, and each on its own would have forced a new aggregator.

<!-- markdownlint-disable MD013 -->

| Parameter | Value | Source |
| -- | -- | -- |
| `factStore` | `0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D` | the round-3 store; the script pins this exact address and refuses any other (`NonCanonicalFactStore`), and additionally requires `MAX_BATCH() == 256` |
| `usdc` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | readback; the script refuses any other |
| `writers` | the three ENG-3926 signer addresses below, same slot order | readback `0x1b17C9b2….writers()` |
| `minLiveSources` | 2 | readback |
| `maxSilence` | 259,200 (3 days) | readback |
| `cycleCloseInterval` | 86,400 (1 day) | readback |
| `seasoningWindow` | 86,400 (24 hours) | readback |
| `maxJumpBps` | 5,000 (50%) | readback |
| **`maxDispersionBps`** | **30,000 (3.0x)** | **Fede's ruling on [ENG-3927](https://linear.app/fabrica/issue/ENG-3927), 2026-09-18 21:32Z — the only THRESHOLD amended; `factStore` is the other of the two fields that differ from the ENG-3926 readback (which was 20,000)** |
| `maxFirstPriceUsdc6` | 50,000,000 USDC (1e6) | readback |
| `valueCeilingUsdc6` | 50,000,000 USDC (1e6) | readback |

<!-- markdownlint-enable MD013 -->

**Every knob was exported explicitly rather than left to the script's `vm.envOr` defaults.**
Omitting an override does not prove an inherited environment is absent. All eleven `FABRICA_*`
variables were confirmed unset in the lane shell and absent from `.env` (grep by name, count 0) and
then exported for both the confirming simulation and the broadcast, so every effective value is
asserted rather than assumed. This is the discipline phase 1 established for
`FACT_STORE_HISTORY_DEPTH`.

**The eleven fields are not eleven defaults.** The script declares exactly **eight** `DEFAULT_*`
constants (`FabricaImmutableAggregatorDeploy.s.sol:65-72`), and `defaults()` returns those eight.
**Seven of them equal what was exported; the eighth, `DEFAULT_MAX_DISPERSION_BPS = 20_000`, does not
and was overridden** — which is exactly why the explicit-export rule matters here rather than being
ceremony.

The other three fields have no default at all and could not have one. `factStore` and `usdc` are
required `vm.envAddress` reads (lines 145-146) standing behind revert guards —
`NonCanonicalFactStore`, `NonCanonicalUsdc`, and the `MAX_BATCH() == 256` staticcall — and `writers`
is a required read guarded by `NoWritersConfigured`, deliberately left without a default because a
guessed writer set would be immutable. **A required input behind a revert is a stronger guarantee
than a default**, not a weaker one: a default silently supplies a value when the operator supplies
none, whereas these three refuse to deploy.

### Why `maxDispersionBps` moved, with the number that moved it

Fede's rationale (ENG-3927, 2026-09-18): under MIN aggregation the lender is always on the low
source, so a wider band buys coverage without raising the lendable price; 2.0x was unpricing parcels
where two land series merely disagree rather than where the data is garbage. Sepolia deploys the
same value the mainnet constructor set will use, so the staging exit rehearses it.

**That is not an abstract preference here — it decides one of the two live tokens.** Measured on the
round-3 store at the deploy, with the aggregator's own integer arithmetic
(`max * 10_000 / min`):

<!-- markdownlint-disable MD013 -->

| Token | Prycd `0xfA2c…` (USDC 1e6) | Regrid `0x24E5…` (USDC 1e6) | max/min | at 20,000 | at 30,000 |
| -- | -- | -- | -- | -- | -- |
| `3443914631469987358` | `38186280000` | `14505000000` | **26,326 bps (2.6326x)** | **`CheckFailed(CHECK_DISPERSION)`** | **passes** |
| `8519383401733904318` | `230842670000` | `148000000000` | 15,597 bps (1.5597x) | passes | passes |

<!-- markdownlint-enable MD013 -->

At the round-2 value this deploy would have shipped a pool that cannot price
`3443914631469987358` at all. `CHECK_DISPERSION` is
`0x13b7448eb34619a801c42321711ec68f930138232e8e73404a2e7c97ab13392a`.

### Land use is not a parameter of this contract

Fede's knob set reads "maxJump 50%, minLiveSources 2, seasoning 24h ON, land-use ON". The first
three are constructor fields and are set above. **Land use is not.** `FabricaImmutableAggregator`'s
`Config` has exactly the eleven fields in the table; `CHECK_LAND_USE`, `ATTR_LAND_USE`,
`requireLandUse` and `setLandUsePolicy` exist only on the round-1 `FabricaOracleAggregator`
(`src/FabricaOracleAggregator.sol:34-61,186`), and the round-2 redesign (ENG-3925) dropped them
along with the rest of the owner surface. Both round-2 aggregators on chain carry no such setting
either.

So the line is carried forward from the 09-02 round-1 knob set and **has no round-3 constructor
argument to bind to**. Nothing was silently dropped, because there was nothing to set. Any land-use
or eligibility gating on the read path is a design question, and it lives in
[ENG-4327](https://linear.app/fabrica/issue/ENG-4327) ("On-chain aggregator must gate on Fabrica
eligibility facts"), not in a deploy parameter. Recorded here rather than left as an apparent
omission a later reader would have to re-derive.

### Guard 8 stays unobservable, deliberately

`maxFirstPriceUsdc6` and `valueCeilingUsdc6` are the same number, exactly as on both round-2
aggregators. Guard 9 (the global ceiling) applies to every valuation and guard 8 (the first-price
cap) only to a first one, so **at these values guard 9 fires first in every case guard 8 would have
caught, and guard 8 is unobservable on this configuration.** It is still implemented, separately
configurable and separately tested.

**This is now a settled decision, not an open one.** ENG-3926's record described a distinct
first-price cap as Tim's open question in
[ENG-4119](https://linear.app/fabrica/issue/ENG-4119); that ticket has since closed **Done** with
the decision to keep the caps equal (Tim, 2026-09-09: "Redundancy is fine. Keep the caps equal.").
The equality here is therefore deliberate and ruled, and carrying the earlier record's wording
forward unchecked would have cited a closed ticket as a live blocker.

## The writer set

Three price sources, in slot order matching `OracleFeedSourceId`, identical to ENG-3926:

<!-- markdownlint-disable MD013 -->

| Slot | Source | Address | `isTrustedWriter` |
| -- | -- | -- | -- |
| 0 | Prycd | [`0xfA2c254f7f4DEf5B0f3CD1D6243F52192D3fC044`](https://sepolia.etherscan.io/address/0xfA2c254f7f4DEf5B0f3CD1D6243F52192D3fC044) | true |
| 1 | OpenAVM | [`0x70ED67c1f4FE4f5a295E5bf3CDadCF54458Da7c7`](https://sepolia.etherscan.io/address/0x70ED67c1f4FE4f5a295E5bf3CDadCF54458Da7c7) | true |
| 2 | Regrid assessor | [`0x24E52f31fc519692A814D73439BB16F44B86DfE1`](https://sepolia.etherscan.io/address/0x24E52f31fc519692A814D73439BB16F44B86DfE1) | true |

<!-- markdownlint-enable MD013 -->

**The fourth signer `0x6a47402083D542E85e883F52607365cFD2186D6E` is deliberately not in this set**,
and `isTrustedWriter` returns **false** for it — verified on chain, stated here because it is the
first question a reader who saw four keeper writers will ask. It writes the token-wide facts (the
Fabrica score, the parcel attributes) that no oracle source produces. Stamping those under a
source's address would tell every reader of this store, the subgraph included, that the source
produced them; in this store the writer address is the provenance, so it has to be true. The
reasoning is ENG-3926's and is unchanged.

One signer per source is forced by the contract, not a preference: `_evaluate` iterates the
immutable writer set and asks the store for one valuation per writer, and the store has no
`sourceId` field, so a source's identity IS its writer address.

## Read-backs from the live chain

Every value below is a `cast call` against the deployed contracts, not an echo of the inputs.

### Aggregator `0x54D671dCc9B00b8c4aE40a664370D515A9FC9D9E`

```text
factStore()            0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D
usdc()                 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
writers()              [0xfA2c254f7f4DEf5B0f3CD1D6243F52192D3fC044,
                        0x70ED67c1f4FE4f5a295E5bf3CDadCF54458Da7c7,
                        0x24E52f31fc519692A814D73439BB16F44B86DfE1]
writerCount()          3
minLiveSources()       2
maxSilence()           259200
cycleCloseInterval()   86400
seasoningWindow()      86400
maxJumpBps()           5000
maxDispersionBps()     30000
maxFirstPriceUsdc6()   50000000000000
valueCeilingUsdc6()    50000000000000
KIND_PRICE()           0x9ef8710b2d7ed0121d9ca0862acabaf24b456f4c111b9e9f438f4e4cc9e7d6d0
isTrustedWriter(0xfA2c254f…)  true
isTrustedWriter(0x70ED67c1…)  true
isTrustedWriter(0x24E52f31…)  true
isTrustedWriter(0x6a474020…)  false
```

The constructor's `AggregatorDeployed` event was emitted in the deploy transaction with the round-3
store and USDC as its indexed topics, so the full rule set is readable from an indexer without an
archive node.

### Pool `0x25dF3D8C3CEBF34a6037b3183f128d8b87275abA`

```text
priceOracle()             0x54D671dCc9B00b8c4aE40a664370D515A9FC9D9E
currencyToken()           0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
collateralToken()         0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD
admin()                   0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83
IMPLEMENTATION_VERSION()  "2.15"
ERC-1967 beacon slot      0x…e1b74cbf78a693e6289dc1c983d8bc2e5097139e
runtime                   451 bytes = 902 hex digits (904 characters with the 0x prefix)
```

**The launch tiers were taken from the live ENG-3926 pool, not from the harness constants.**
`durations()` and `rates()` were read off `0x42C26Fd0…` with `cast call` before this pool was
created and compared against the script's `_defaultDurations()` / `_defaultRates()`; all three match
byte for byte, and the new pool reads back the same arrays. Reading the live pool rather than
trusting a vendored copy is the check that a drifted constant cannot pass.

<!-- markdownlint-disable MD013 -->

| | Values |
| -- | -- |
| `durations()` | 62208000, 31104000, 23328000, 15552000, 10368000, 7776000, 5184000, 2592000 |
| `rates()` | 1585489599, 2219685438, 3170979198, 4122272957, 4756468797, 5390664637, 6341958396, 7927447995 |

<!-- markdownlint-enable MD013 -->

No ownership-finalize step was run: `admin()` is the factory, exactly as on the ENG-3926 pool, and
that record ran none either.

**The pool's creation transaction is recorded here rather than in the repo that ran it.** Foundry
wrote that broadcast record into `fabrica-land/metastreet-contracts-v2`, which this PR does not
touch and where nothing would have committed it, so the only copy lived in a scratch clone. It is
carried into this repository verbatim as
[`ENG-4203-round3-pool-broadcast.json`](./ENG-4203-round3-pool-broadcast.json) — byte-identical to
`broadcast/FabricaLendingPoolCreateWithAggregator.s.sol/11155111/run-1789773434028.json` as produced
by `script/FabricaLendingPoolCreateWithAggregator.s.sol` in
[`fabrica-land/metastreet-contracts-v2`](https://github.com/fabrica-land/metastreet-contracts-v2) at
`cfc14eb6e7eefaf0cf130916e1a61076467fe046` (`main`), sha256
`3aa1f1d240b93c84c322a6aae65be0a083fe9182f9b16524f8551015ffb8ff6d`. It holds the `createProxied`
call, its receipt and logs, and the inner `CREATE` of the pool with its init code. It carries no key
material: a case-insensitive grep over the file for
`private|privatekey|secret|mnemonic|password|keystore|seed|passphrase` returns **0 matching
lines**, and an enumeration of every JSON path in it finds only
chain data — receipts, logs, and the transaction envelope (`from`, `to`, `nonce`, `gas`, `input`,
`value`). There are no signature fields at all. That is the measurement, not the rule; Foundry's
sensitive values live in the separate `cache/` file, which was shredded.

### `price()` — a real price on both tokens

Chain time 1,789,773,468 (2026-09-18 23:17:48Z), `collateralToken` = FabricaToken,
`currencyToken` = USDC, quantity 1, empty `oracleContext`:

<!-- markdownlint-disable MD013 -->

| Token | `eligibilityReport` | `price()` (USDC 1e6) | In USDC |
| -- | -- | -- | -- |
| `3443914631469987358` | `(true, 0x00…00)` | `14505000000` | 14,505.00 |
| `8519383401733904318` | `(true, 0x00…00)` | `148000000000` | 148,000.00 |

<!-- markdownlint-enable MD013 -->

Both equal the MIN source (Regrid), which is what the contract is supposed to return and what the
pre-broadcast prediction said it would: `historyLength` is 0 on all four rows, so guard 8 applies
and passes (both values are far below the 5e13 cap), the jump breaker has no baseline and cannot
fire, and `_applyTemporalFloor` finds no history at `block.timestamp - 86400`, leaving `usable` at
`currentMin`.

This is the first round-3 price. No round-2-backed pool is quoting — both round-2 aggregators have
been failing `CHECK_MAX_SILENCE` since the ENG-4202 keeper stand-down, as the phase 1 record
measured.

### Source liveness at deploy time: 2-of-3, at the floor

<!-- markdownlint-disable MD013 -->

| Writer | `lastCycleClose` | `3443914631469987358` | `8519383401733904318` |
| -- | -- | -- | -- |
| Prycd `0xfA2c254f…` | cycle 20714, closedAt 1,789,772,304 | live, `38186280000` | live, `230842670000` |
| OpenAVM `0x70ED67c1…` | cycle 20714, closedAt 1,789,772,280 | **not live** | **not live** |
| Regrid `0x24E52f31…` | cycle 20714, closedAt 1,789,772,244 | live, `14505000000` | live, `148000000000` |

<!-- markdownlint-enable MD013 -->

All three writers have a fresh cycle close, so `freshCount` = **3** on both tokens and
`CHECK_MAX_SILENCE` passes. OpenAVM holds no live `KIND_PRICE` fact for either token, so
`liveCount` = **2** on both tokens — exactly `minLiveSources`, with **zero margin**. One Prycd or
Regrid dropout takes both tokens to `CHECK_MIN_SOURCES`.

The distinction the contract draws here is the one worth reading: a writer can be perfectly live as
a feed and still hold no usable valuation for a token. That is why the report says `max_silence`
when the feeds are dark and `min_sources` when the feeds are up but the token is not priceable.

This is [ENG-4301](https://linear.app/fabrica/issue/ENG-4301) — staging AVM has produced no usable
valuation since 2026-06-23 — observed live, and it is Fede's own third follow-up on ENG-3927: until
it is fixed, 2-of-3 is not actually being rehearsed, because every Prycd/Regrid disagreement is the
only disagreement there is. **Recorded as the known state at deploy, not as a defect of this
deployment.**

## What is NOT changed

Verified by `cast call` after the deploy:

<!-- markdownlint-disable MD013 -->

| Deployment | Sepolia address | State after this deploy |
| -- | -- | -- |
| Round-1 pool | `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B` | `priceOracle()` = `0x522C7F01B535b36eca6b27C32A65Ee79e7c4df45` (unchanged) |
| ENG-3925 pool | `0xdE70d398Be943BB1CCd77a5c081e38046Ca17764` | `priceOracle()` = `0xbDD420cB9b171e743EDb8Ad7584aF52347F6CA57` (unchanged) |
| ENG-3926 pool | `0x42C26Fd01B0D8217eDD5009078D6A53c6eE023E5` | `priceOracle()` = `0x1b17C9b2a5C0d8E9717b84eD4B214a4d2CedA52b` (unchanged) |
| Round-2 fact store | `0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd` | runtime still 6,036 bytes, unchanged |
| Round-3 fact store | `0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D` | runtime 6,393 bytes, `MAX_BATCH()` 256 — **read only; this deploy writes nothing to it** |

<!-- markdownlint-enable MD013 -->

The round-2 pools' disposition remains the open question filed on ENG-4203 on 2026-09-14. This
deployment does not answer it and does not change it.

## Verification on Etherscan: the aggregator is verified, the pool is not

**Aggregator — verified.** Etherscan verification ran inside the same broadcast and returned
`Pass - Verified`. Confirmed independently afterwards through the Etherscan **v2** API rather than
`cast interface`, which queries the legacy endpoint and misreports verified contracts (see
`DEPLOYMENT.md`): `ContractName` `FabricaImmutableAggregator`, `CompilerVersion`
`v0.8.35+commit.47b9dedd`, `OptimizationUsed` 1, `Runs` 1, source present.

**Pool — not source-verified on Etherscan today, and not verifiable from THIS repository.** Read
that scope literally: it is a statement about the explorer's current state and about this repo's
build, and **not** a claim that the pool's bytecode is unidentified. It is identified — the runtime
is byte-exact to `metastreet-contracts-v2`'s `BeaconProxy`, established below. The verification
attempt was made, not assumed. The `BeaconProxy` constructor arguments were reconstructed from
first principles — `abi.encode(beacon, abi.encodeWithSignature("initialize(bytes)", params))`, with
the reconstructed `params` measuring 800 bytes against the deploy script's own logged `Params len:
800` — and `forge verify-contract` was run against
`lib/openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol:BeaconProxy`. Etherscan returned
`Fail - Unable to verify.`

The reason that attempt failed is structural: **this repository does not reproduce the DEPLOYED
creation code.** It compiles a `BeaconProxy` creation code of its own — 1,396 bytes, in the table
below — but not the one that created this pool, which is embedded in already-deployed code.
Precisely where: `PoolFactory` at
`0x110bD404…` is itself an ERC-1967 proxy whose own runtime is only **89 bytes** of forwarder; its
implementation slot (`0x360894a1…382bbc`) holds `0x67Ec95b78404f1Fc5713adC809EE6e859884E581`, whose
**5,894-byte** runtime is what actually carries the `BeaconProxy` creation code that `new
BeaconProxy(...)` emits. Saying "embedded in the factory's runtime" would point a verifier at 89
bytes that contain no such thing.

**The deployed pool's runtime IS `metastreet-contracts-v2`'s `BeaconProxy` from the cited tree.**
That is a byte-level result, and it is the provenance claim this section should have made from the
start. Measured against the clone at `cfc14eb6e7eefaf0cf130916e1a61076467fe046` built with that
repo's own profile:

<!-- markdownlint-disable MD013 -->

| Measure | Value |
| -- | -- |
| Deployed pool `0x25dF3D8C…` runtime (`cast code`, a chain readback) | 451 bytes |
| That repo's build **as its `foundry.toml` stands** (`cbor_metadata = false`) | 439 bytes |
| `deployed[0:439]` vs that build | **byte-for-byte identical — 0 differing offsets** |
| The 12-byte remainder | `a164736f6c6343000819000a` |
| The same tree rebuilt with **`cbor_metadata = true`** (`bytecode_hash` left `None`) | 451 bytes |
| **Full runtime, all 451 bytes, vs that rebuild** | **byte-for-byte identical — 0 differing offsets** |

<!-- markdownlint-enable MD013 -->

Those 12 bytes are the **CBOR metadata trailer**: `a1` is a one-pair map, `64 736f6c63` the key
`"solc"`, and `43 000819` a three-byte value `00 08 19` = **0.8.25** — the compiler the metastreet
row names — followed by the two-byte length suffix `000a` (10, the CBOR item's length). It is
absent from the local build for a stated reason, not a mysterious one — `metastreet-contracts-v2`'s
`foundry.toml` sets `bytecode_hash = "None"` and `cbor_metadata = false` (lines 15-16), so its
builds **suppress** the trailer that the deployed bytecode carries. The deployed pool therefore
differs from that repo's build in exactly the span its build configuration removes, and nowhere
else.

**That is not an inference, it is a measurement.** Rebuilding the same tree with
`cbor_metadata = true` (leaving `bytecode_hash = "None"`, and overriding only through the
environment so the clone's `foundry.toml` is untouched) emits a **451-byte** runtime whose every
byte equals the deployed pool's `cast code` — **0 differing offsets across all 451**, the trailing
`a164736f6c6343000819000a` included. So the match is the **whole runtime**, not a 439-byte prefix,
and no part of it rests on argument about what the missing span "would have been".

This repository's build is the one that does not match: OZ 5.3.0 produces 283 bytes, a different
contract generation entirely.

<!-- markdownlint-disable MD013 -->

| Source | OpenZeppelin | Build settings | `BeaconProxy` runtime | Against the deployed 451 |
| -- | -- | -- | -- | -- |
| Deployed pool `0x25dF3D8C…` (**chain readback**, `cast code`) | — | — | **451 bytes** | — |
| `metastreet-contracts-v2` @ `cfc14eb6`, which ran the create | 4.9.6 | solc 0.8.25, optimizer on `runs = 1`, via-IR, `evmVersion` cancun | **439 bytes** | **exact match on all 439**, + the suppressed 12-byte trailer |
| This repository (`lib/openzeppelin-contracts`) | 5.3.0 | solc 0.8.35, optimizer on `runs = 1`, no via-IR, `evmVersion` osaka | **283 bytes** (creation code 1,396) | no match; different generation |

<!-- markdownlint-enable MD013 -->

**The two build rows** are the compiler's own `deployedBytecode.object` length, not `wc`; the first
row is not a build at all but a chain readback (`cast code`, whose 905-character output is 451
bytes). Each build row's settings are read from **that artifact's own `metadata`**, not from its
repo's `foundry.toml` — in
`metastreet-contracts-v2` those differ, because its `compilation_restrictions` pull `BeaconProxy`
into the `runs = 1` unit with `PoolFactory` rather than leaving it at the profile's `runs = 800`.

The two builds differ from each other for a structural reason, not a settings one: OZ 5.3.0's
`BeaconProxy` holds the beacon in an `immutable` (`address private immutable _beacon`, and the
artifact declares one 32-byte `immutableReferences` span), while OZ 4.9.6's reads it from the
ERC-1967 beacon slot on every call and declares no immutables. The deployed pool answers its beacon
out of that storage slot — `cast storage` at `0xa3f0ad74…133d50` returns `0xe1B74Cbf…`, shown in the
read-backs above — so it is the storage-slot generation, which is what the runtime match says too.

An earlier revision of this record said "the `BeaconProxy` this tree builds is 439 bytes". That
number is real but belongs to `metastreet-contracts-v2`, not to "this tree" — a reader in this
repository would have tried to reproduce 439 here and got 283. Both are now named with their repo,
their OZ version and their settings.

### The creation code is a different question, and it is NOT reproduced

Runtime provenance does not carry over to the creation code, and Etherscan verifies against the
creation side. Measured:

<!-- markdownlint-disable MD013 -->

| Measure | Value |
| -- | -- |
| `initCode` in the pool's broadcast record | 2,572 bytes |
| …of which constructor arguments (`abi.encode(address,bytes)`) | 992 bytes |
| …leaving deployed creation code | 1,580 bytes, carrying the same CBOR trailer at offset 1,568 |
| `metastreet-contracts-v2` build's creation code | 1,536 bytes |
| Differing offsets across the 1,536-byte common prefix | **664** |

<!-- markdownlint-enable MD013 -->

664 differing offsets is not a near-miss. The likely cause is the same whole-unit sensitivity that
repo documents for itself: under via-IR a contract's output depends on which *other* contracts share
its solc job, and the embedded proxy was emitted by whatever unit compiled `PoolFactory` at deploy
time. Stated as the plausible cause it is, not as a finding — nothing here isolates it.

### What this record does and does not claim about Etherscan

**Claimed, because it was measured:** the pool's deployed runtime is byte-exact to
`metastreet-contracts-v2`'s `BeaconProxy` at `cfc14eb6`, over all 439 bytes that repo's
configuration emits, with the 12-byte metadata trailer as the only difference and a stated reason
for it — **and over all 451 bytes, with zero differing offsets and nothing left over, once that
tree is rebuilt with `cbor_metadata = true`.** The 439-byte form is the scoped claim against the
repo as it stands; the 451-byte form is the whole runtime and needs no scoping at all.

**Not claimed:** that an Etherscan submission from that tree would succeed. **It was never
attempted.** The one attempt made was from *this* repository and returned
`Fail - Unable to verify.`, which is unsurprising given the 283-vs-451 mismatch and says nothing
about the metastreet tree. The creation-code divergence above is a reason to expect difficulty, not
a demonstration of failure. An earlier revision of this record asserted that "no build of either
repository can verify that address, and no future attempt from either will succeed" — **that was an
over-reach contradicted by the bytes above, and it is withdrawn.** Whether a metastreet-side
submission verifies is an open, testable question, tracked in
[ENG-4333](https://linear.app/fabrica/issue/ENG-4333) along with the beacon implementation, and
deliberately not attempted inside a deploy ticket.

### Corroborating reads

The runtime match above is the provenance. These are consistency checks around it, not the claim:

<!-- markdownlint-disable MD013 -->

| Check | Result |
| -- | -- |
| Same proxy code as the reference pool | Round-3 pool runtime is byte-identical to the ENG-3926 pool's — both 451 bytes |
| Same beacon | ERC-1967 beacon slot holds `0xe1B74Cbf…`, the shared `UpgradeableBeacon` |
| Same logic | `IMPLEMENTATION_VERSION()` `"2.15"`; beacon `implementation()` `0x78F794373E7B4b2fCF86987C70abdA0e12fE9BB5` |
| Correctly wired | `priceOracle()`, `currencyToken()`, `collateralToken()`, `admin()`, `durations()`, `rates()` all read back as intended |

<!-- markdownlint-enable MD013 -->

**The explorer state is not something this deploy introduced.** Three contracts were checked
through the Etherscan v2 API, and the claim is about those three and no others: the round-3 pool
`0x25dF3D8C3CEBF34a6037b3183f128d8b87275abA`, the ENG-3926 pool
`0x42C26Fd01B0D8217eDD5009078D6A53c6eE023E5`, and the shared beacon implementation
`0x78F794373E7B4b2fCF86987C70abdA0e12fE9BB5`.

<!-- markdownlint-disable MD013 -->

| Address checked | `Proxy` | `Implementation` | `SourceCode` |
| -- | -- | -- | -- |
| Round-3 pool `0x25dF3D8C…` | 1 | `0x78F79437…` | **absent** |
| ENG-3926 pool `0x42C26Fd0…` | 1 | `0x78F79437…` | **absent** |
| Beacon implementation `0x78F79437…` | 0 | — | **absent** |

<!-- markdownlint-enable MD013 -->

The shared fact across all three is the one that matters here: **no source on the explorer.** The
two pools additionally resolve as proxies; the implementation is not a proxy and returns `Proxy:
0`, which is what it should return and is recorded so the row is not read as a fourth proxy. The
round-1 pool, the `PoolFactory` and its own implementation were **not** checked, so nothing here is
claimed about them — "the whole Sepolia lending stack" would have generalised past the evidence.
Round 3 is at exact parity with the pool this record reproduces. Explorer verification of the
beacon implementation and the factory's embedded proxy code is
[ENG-4333](https://linear.app/fabrica/issue/ENG-4333), filed separately so it is not re-attempted
inside a deploy ticket.

## Bytecode provenance (aggregator)

The deployed executable code IS this source's output.

<!-- markdownlint-disable MD013 -->

| Measure | Value |
| -- | -- |
| Local rebuild runtime | 7,148 bytes |
| On-chain runtime | 7,148 bytes |
| Immutable spans, **from the compiler's own `immutableReferences`** | 37 spans across 19 slots, 1,184 bytes |
| Total differing offsets | 218 |
| Differing offsets inside declared immutable spans | 218 |
| **Differing offsets outside the declared immutable spans** | **0** |

<!-- markdownlint-enable MD013 -->

The size agreement is a **consistency check, not proof** — two different contracts can share a byte
count. What establishes provenance is byte identity with the immutable spans masked, and the spans
here are the ones the compiler declares in `immutableReferences` rather than ones inferred from the
diff, so the masking cannot be fitted to the answer.

**A note on which region, because two records now quote different numbers for it.** ENG-3926
reported a "7,095-byte executable region": that is the runtime minus the 53-byte CBOR trailer. The
masked region above is **5,964 bytes** — the runtime minus the 1,184 immutable bytes — and it
*includes* the CBOR trailer. Both figures are correct for what they measure and both show zero
differences; they are not in conflict, and a verifier comparing the two records should not read the
difference as drift.

The trailing **53-byte CBOR metadata** holds a 32-byte IPFS hash digesting the compiler's *input*
JSON and is build-environment dependent. It matched here only because this rebuild ran on the
machine that produced the deploy. **With the 37 declared immutable spans masked, a rebuild anywhere
else differs in exactly that span and nowhere else, which is expected and is not evidence of
tampering.** The masking qualifier matters: unmasked, an off-machine rebuild differs across those
1,184 immutable bytes as well — that is the 218 differing offsets above, which this deploy's own
on-machine rebuild still shows. Reproduce the masked result, not the whole-runtime one.

## Before the broadcast

The parameter table went to Brioche and came back approved before anything was signed. Ahead of
that:

The deploy was simulated against Sepolia without `--broadcast`, with the complete explicit
environment. The script's own intended-versus-deployed gate ran inside the simulation and reported
`Intended and deployed parameters agree on every field.`, with `maxDispersionBps 30000` in **both**
the INTENDED and DEPLOYED blocks — so the override was proven to reach the constructor before it was
broadcast, not after.

The fork suites were run deliberately, with the RPC configured and the loud flag set, as a
precondition of the broadcast rather than inferred from CI:

```sh
set -a; . ./.env; set +a
FABRICA_REQUIRE_SEPOLIA_FV=1 forge test \
  --match-contract "Eng3925ImmutableAggregatorSepoliaForkTest|Eng4203Round3FactStorePinSepoliaForkTest" -vv
```

Result: `26 tests passed, 0 failed, 0 skipped` across the two suites. **The load-bearing number is
the zero skips** — without `FABRICA_REQUIRE_SEPOLIA_FV=1` a missing RPC makes a fork suite skip and
report `ok`, which is indistinguishable from a pass at a glance. A run reporting any skips has
verified nothing and does not authorise a broadcast.

The round-3 store was confirmed round-3-shaped by execution rather than by reading its address:
`MAX_BATCH()` returns 256 and `historyDepth()` returns 48. The script's own guard re-checks
`MAX_BATCH() == 256` on every run and would have refused the deploy otherwise.

## How this was deployed, and the key that was not used

Per `DEPLOYMENT.md` § "`TESTNET_DEPLOYER_PRIVATE_KEY` is fenced". That key is the ENG-3895
cycle-close runner EOA and **was not used**.

A **disposable keystore generated in-process**: the keypair was created inside a short script that
wrote the encrypted V3 JSON keystore and a random password file (both `0600`, in a `0700` directory
outside the repo) and printed only the address. The key never reached argv, the environment, a log
or command output. Before any funds moved, the keystore was decrypted back and checked to derive
the expected address — a mismatch there would have stranded the funding.

<!-- markdownlint-disable MD013 -->

| Step | Value |
| -- | -- |
| Disposable deployer | `0x3477f46eA936c053D6bb658fcbb2920e7F21C309` (balance 0, nonce 0, no code beforehand) |
| Funding | 0.05 SepoliaETH from the shared pool `0x152e6102AACf29694f75Efbf424f1f017FD3813F`, tx [`0xb5746684…5dae`](https://sepolia.etherscan.io/tx/0xb574668495eeb67b0e40783e3fac374b280b9bfeab0967b70b6fcf52d43b5dae) |
| Sweep back | 0.046618338191223690 ETH, tx [`0x55418e1d…dffe4`](https://sepolia.etherscan.io/tx/0x55418e1d5295cd68fca826f35d781008cccfd2eb94a2e8367fbddf1f754dffe4), status 1, block 11,733,853, `gasUsed` 21,000 |
| Gas consumed by the two deploys and the sweep | 0.003369636051445310 ETH |
| Final nonce | 3 |

<!-- markdownlint-enable MD013 -->

**0.000012025757331 ETH is stranded** at `0x3477f46eA936c053D6bb658fcbb2920e7F21C309` permanently;
the key was destroyed after the sweep. The sweep reserved three times the quoted gas price as
headroom so it could not itself fail for under-pricing, and the unspent headroom is the stranding.
That is below both predecessors on this path — ENG-3926's 8.15e-5 and phase 1's 5.66e-5. Recorded
rather than rounded away: it is the standing cost of the disposable-keystore path.

Sweep happened **before** shredding. The keystore, its password file and all six Foundry
sensitive-values files under `cache/` in both repositories — including the pre-broadcast dry-run
ones — were then random-overwritten and unlinked; a post-shred sweep found zero remaining. **The
`broadcast/` records were deliberately preserved** — they are the non-sensitive historical record
and are committed with this change.

The wallet pool cannot carry a contract's init code, which is why the keystore path exists at all;
ENG-3925 spent ~0.0033 ETH on a status-0 transaction establishing that. The pool creation is a
plain `CALL` and could in principle have gone through the pool's send path, but it was signed with
the same disposable key so that the aggregator and the pool are one atomic sitting with one key
lifecycle, rather than two.

## Downstream

The pool address is what [ENG-4205](https://linear.app/fabrica/issue/ENG-4205) (subgraph),
[ENG-3929](https://linear.app/fabrica/issue/ENG-3929) and
[ENG-3930](https://linear.app/fabrica/issue/ENG-3930) consume, and re-pointing the API and Soil
configuration at it is [ENG-4205](https://linear.app/fabrica/issue/ENG-4205)'s work and explicitly
not this record's. **Neither ticket is satisfied by this deployment** — it gives them an address,
not completion.

`fabrica-land/metastreet-contracts-v2` needs no change: its
`script/FabricaLendingPoolCreateWithAggregator.s.sol` takes the oracle as an `IPriceOracle` and the
round-3 aggregator keeps that interface, so it created this pool unmodified.
