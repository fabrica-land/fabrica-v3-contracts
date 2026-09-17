# ENG-3926 — the real oracle writer's aggregator and its Sepolia pool

[ENG-3926](https://linear.app/fabrica/issue/ENG-3926). Sepolia only. Contract:
`src/FabricaImmutableAggregator.sol`, unchanged. Deploy script:
`script/FabricaImmutableAggregatorDeploy.s.sol`, unchanged.

**This ticket changes no contract and no script. It deploys the existing aggregator a second
time with a different trusted writer set, and creates a pool pointed at it.** Every other
constructor value is identical to the shipped
[ENG-3925](https://linear.app/fabrica/issue/ENG-3925) aggregator, read back off chain rather
than copied from that record.

## Why a redeploy was the only option

The shipped aggregator
[`0xbDD420cB9b171e743EDb8Ad7584aF52347F6CA57`](https://sepolia.etherscan.io/address/0xbDD420cB9b171e743EDb8Ad7584aF52347F6CA57)
holds its trusted writer set in `immutable` slots. Its three writers are the **lane-generated
rehearsal EOAs** ENG-3925 deployed with — `0x89C52827…`, `0x16d37D50…`, `0xDc3B2ECe…` — whose
keys died with that lane. ENG-3926 gives the writer real signers the API service holds, and
there is no writer allowlist anywhere to update: the round-2 `FabricaFactStore` authorises no
particular writers, so the only way a source's prices reach a pool is for the aggregator's
immutable constructor argument to already hold that source's address. Adopting real signers is
therefore a new aggregator and a new pool. That is the round-2 design working as intended.

Writing to the same store from the new keys against the *shipped* aggregator would be accepted
by the store and silently ignored by that feed. Nothing on the write side reports the mistake.

**The shipped ENG-3925 pool `0xdE70d398…` goes dark on its own.** Its three writers' last cycle
closes were recorded at 1788897708 / 1788897708 / 1788896976, and nobody holds the keys to
refresh them, so at `maxSilence` of 3 days `price()` starts failing `CHECK_MAX_SILENCE` around
2026-09-11. That is fail-closed by design, not an incident. **Round-2 consumers should point at
the pool in this record, not that one.**

## What is NOT changed

Every existing deployment stays up and serving. Verified by `cast call` after the deploy:

<!-- markdownlint-disable MD013 -->

| Deployment | Sepolia address | `priceOracle()` after this deploy |
| -- | -- | -- |
| Round-1 pool | `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B` | `0x522C7F01B535b36eca6b27C32A65Ee79e7c4df45` (unchanged) |
| ENG-3925 round-2 pool | `0xdE70d398Be943BB1CCd77a5c081e38046Ca17764` | `0xbDD420cB9b171e743EDb8Ad7584aF52347F6CA57` (unchanged) |

<!-- markdownlint-enable MD013 -->

The round-2 fact store `0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd` is shared and untouched:
this aggregator reads the same store the shipped one reads.

## Constructor parameters

Ten of the eleven are the shipped aggregator's values, **read back from `0xbDD420cB…` on chain
before this deploy, never from the ENG-3925 record**. Only `writers` differs.

<!-- markdownlint-disable MD013 -->

| Parameter | Value | Source |
| -- | -- | -- |
| `factStore` | `0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd` | readback; the script refuses any other (`NonCanonicalFactStore`) |
| `usdc` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | readback; the script refuses any other |
| `writers` | the three ENG-3926 signer addresses below | **the only change in this deploy** |
| `minLiveSources` | 2 | readback |
| `maxSilence` | 259,200 (3 days) | readback |
| `cycleCloseInterval` | 86,400 (1 day) | readback |
| `seasoningWindow` | 86,400 (24 hours) | readback |
| `maxJumpBps` | 5,000 | readback |
| `maxDispersionBps` | 20,000 | readback |
| `maxFirstPriceUsdc6` | 50,000,000 USDC | readback |
| `valueCeilingUsdc6` | 50,000,000 USDC | readback |

<!-- markdownlint-enable MD013 -->

### Guard 8 stays unobservable, deliberately

`maxFirstPriceUsdc6` and `valueCeilingUsdc6` are the **same number** here, exactly as on the
shipped aggregator. Guard 9 (the global ceiling) applies to every valuation and guard 8 (the
first-price cap) only to a first one, so **at these values guard 9 fires first in every case
guard 8 would have caught, and guard 8 is unobservable on this configuration.** It is still
implemented, separately configurable and separately tested. Choosing a distinct first-price cap
is Tim's open decision in [ENG-4119](https://linear.app/fabrica/issue/ENG-4119) for the
production deploy; this Sepolia redeploy deliberately changes no parameter but the writer set,
so the two aggregators stay comparable.

## The writer set

Three price sources, in slot order matching `OracleFeedSourceId` (0 = Prycd, 1 = OpenAVM,
2 = Regrid assessor):

<!-- markdownlint-disable MD013 -->

| Slot | Source | Address |
| -- | -- | -- |
| 0 | Prycd | [`0xfA2c254f7f4DEf5B0f3CD1D6243F52192D3fC044`](https://sepolia.etherscan.io/address/0xfA2c254f7f4DEf5B0f3CD1D6243F52192D3fC044) |
| 1 | OpenAVM | [`0x70ED67c1f4FE4f5a295E5bf3CDadCF54458Da7c7`](https://sepolia.etherscan.io/address/0x70ED67c1f4FE4f5a295E5bf3CDadCF54458Da7c7) |
| 2 | Regrid assessor | [`0x24E52f31fc519692A814D73439BB16F44B86DfE1`](https://sepolia.etherscan.io/address/0x24E52f31fc519692A814D73439BB16F44B86DfE1) |

<!-- markdownlint-enable MD013 -->

**One signer per source is forced by the contract, not a preference.** `_evaluate` iterates the
immutable writer set and asks the store for one valuation per writer; the round-2 store has no
`sourceId` field at all, so a source's identity IS its writer address. A single signer shared
across the three sources would present as one source, and `minLiveSources = 2` would refuse
every read with `CHECK_MAX_SILENCE`.

There is a **fourth** signer, `0x6a47402083D542E85e883F52607365cFD2186D6E`, which is
**deliberately not in this set** — `isTrustedWriter` returns false for it, verified below. It
writes the token-wide facts (the Fabrica score, the parcel attributes) that no oracle source
produces. Stamping those under a source's address would tell every reader of this store, the
subgraph included, that the source produced them; in this store the writer address is the
provenance, so it has to be true.

The signers' private keys live in the API's sops-encrypted config, referenced by config path
and variable name only. `OracleWriterSignerService` refuses to start if a key does not derive
to its configured `expectedAddress` — necessary because a misdirected writer gets no error from
the store, only a source that silently never appears.

## Deployed addresses

<!-- DEPLOYMENT:sepolia -->

| Contract | Network | Address |
| -- | -- | -- |
| `FabricaImmutableAggregator` | Sepolia | [`0x1b17C9b2a5C0d8E9717b84eD4B214a4d2CedA52b`](https://sepolia.etherscan.io/address/0x1b17C9b2a5C0d8E9717b84eD4B214a4d2CedA52b) |
| Round-2 oracle pool (`BeaconProxy`) | Sepolia | [`0x42C26Fd01B0D8217eDD5009078D6A53c6eE023E5`](https://sepolia.etherscan.io/address/0x42C26Fd01B0D8217eDD5009078D6A53c6eE023E5) |

<!-- /DEPLOYMENT:sepolia -->

Aggregator deployed 2026-09-09 in transaction
[`0xf7b9c425…e8d7`](https://sepolia.etherscan.io/tx/0xf7b9c425c897d28af97f688883719f752bef0d3eae42cd1aa5a61fffb9fae8d7),
status `0x1`, gas used `0x193ba9`, block `0xb210fc`; Etherscan-verified in the same run
(`Pass - Verified`, solc 0.8.35, optimizer on, `runs = 1`).

Pool created through the live `PoolFactory` in
[`0x5ce258be…ab1f`](https://sepolia.etherscan.io/tx/0x5ce258beec25df45068e952d9123ed1c925c86650b88a1b287a674ad304cab1f),
status 1, gas used 522,200, block 11,669,767.

<!-- markdownlint-disable MD013 -->

| Component | Sepolia address |
| -- | -- |
| `PoolFactory` | `0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83` |
| Pool beacon (`UpgradeableBeacon`) | `0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e` |
| Collateral token (`FabricaToken`) | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` |
| Currency token (USDC) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

<!-- markdownlint-enable MD013 -->

Pool readback: `priceOracle()` = this aggregator, `currencyToken()` = USDC, `admin()` = the
factory, `isPool` true, `IMPLEMENTATION_VERSION` `2.15`, ERC-1967 beacon slot holds the shared
beacon, 905 hex characters of runtime.

**The launch tiers were taken from the shipped pool, not from the harness constants.** The
durations and rates were read off `0xdE70d398…` with `cast call` and compared before creating
this pool; both arrays match byte for byte. Reading the live pool rather than trusting a
vendored copy is the check that a drifted constant cannot pass.

`fabrica-land/metastreet-contracts-v2` needs no change: its
`script/FabricaLendingPoolCreateWithAggregator.s.sol` takes the oracle as an `IPriceOracle`,
and the round-2 aggregator keeps that interface.

## Bytecode provenance

The deployed executable code IS this source's output. Full literal output is in the PR's
verification comment; the result:

<!-- markdownlint-disable MD013 -->

| Measure | Value |
| -- | -- |
| Local rebuild runtime | 7,148 bytes |
| On-chain runtime | 7,148 bytes |
| Immutable spans, **from the compiler's own `immutableReferences`** | 37 spans across 19 slots, 1,184 bytes |
| Total differing offsets | 218 |
| Differing offsets inside declared immutable spans | 218 |
| **Differing offsets across the 7,095-byte executable region** | **0** |

<!-- markdownlint-enable MD013 -->

The size agreement is a **consistency check, not proof** — two different contracts can share a
byte count. What establishes provenance is the executable-region byte identity with the
immutable spans masked, and the spans here are the ones the compiler declares in
`immutableReferences` rather than ones inferred from the diff, so the masking cannot be fitted
to the answer.

The trailing **53-byte CBOR metadata** holds a 32-byte IPFS hash digesting the compiler's
*input* JSON and is build-environment dependent. It matched here only because this rebuild ran
on the machine that produced the deploy. **With the 37 declared immutable spans masked, a rebuild
anywhere else differs in exactly that span and nowhere else, which is expected and is not evidence
of tampering.** The masking qualifier matters: unmasked, an off-machine rebuild differs across
those 1,184 immutable bytes as well — that is the 218 differing offsets in the table above, which
this deploy's own on-machine rebuild still shows. Reproduce the executable-region result, not the
whole-runtime one.

## Before the broadcast

The fork suite was run deliberately, with the RPC configured and the loud flag set, as a
precondition of the broadcast rather than inferred from CI:

```sh
set -a; . ./.env; set +a
FABRICA_REQUIRE_SEPOLIA_FV=1 \
  forge test --match-contract Eng3925ImmutableAggregatorSepoliaForkTest -vv
```

Result: `Suite result: ok. 24 passed; 0 failed; 0 skipped`.

**That is 24, where the ENG-3925 record states 23.** The count moved between that record and
this one; nothing was skipped in either. The load-bearing number is the zero skips — without
`FABRICA_REQUIRE_SEPOLIA_FV=1` a missing RPC makes the suite skip and report `ok`, which is
indistinguishable from a pass at a glance. A run reporting any skips has verified nothing and
does not authorise a broadcast.

The script's own intended-versus-deployed readback also ran inside the broadcast and reported
`Intended and deployed parameters agree on every field.`

## How this was deployed, and the key that was not used

`.env`'s `TESTNET_DEPLOYER_PRIVATE_KEY` is the **fenced ENG-3895 cycle-close runner EOA**
(`0xBF03…69dF`). It was not used: that runner owns the key's nonce and is live. See
`DEPLOYMENT.md`, which this ticket updates with the rule and the lane path.

This deploy used a **disposable keystore generated in-process** — the key never reached argv,
the environment, a log or command output; only its address was printed — funded 0.05 ETH from
the shared wallet pool, used via `--keystore` / `--password-file`, then swept back to the pool
(0.047565977285489305 ETH returned in
[`0xcc8a3241…8deb`](https://sepolia.etherscan.io/tx/0xcc8a3241c934874098e963937d1357daf808c490608814f8aa8dce3d70788deb)),
after which the keystore, its password file and Foundry's `cache/…/run-latest.json`
sensitive-values file were overwritten and deleted.

**0.0000815 ETH is stranded** at `0x753Bf642cC405d8441400E5E1173C70571e1BFf6` permanently: one
transaction's worth of dust could not be swept, and the key was then destroyed. Recorded rather
than rounded away — it is the standing cost of the disposable-keystore path.

The wallet pool cannot carry a contract's init code, which is why the keystore path exists at
all; ENG-3925 spent ~0.0033 ETH on a status-0 transaction establishing that.
