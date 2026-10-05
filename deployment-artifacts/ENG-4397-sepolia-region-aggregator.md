# ENG-4397 — Sepolia region rule aggregator

This is the Sepolia-only `FabricaRegionRuleAggregator` (PR #59) deploy. It adds
a jurisdiction rule — country and region gating on the `fabrica.fact.jurisdiction`
fact — on top of the ENG-4414 successor eligibility aggregator's shape. No
mainnet transaction was sent.

## Deployment

| Item | Value |
| --- | --- |
| Chain | Sepolia, `11155111` |
| Contract | [`0xe268C436ffb482c32709ed1e038500429378cA59`](https://sepolia.etherscan.io/address/0xe268c436ffb482c32709ed1e038500429378ca59) |
| Deploy transaction | [`0xd15d9ad598968c2c2859be78d29ccd85968904073061fcb9a96e6098bc803cb3`](https://sepolia.etherscan.io/tx/0xd15d9ad598968c2c2859be78d29ccd85968904073061fcb9a96e6098bc803cb3) |
| Receipt | `status=1`, `from=0x17F3274defEB99dB037b726b58DFFFE27530892F`, `to=null`, `contractAddress=0xe268C436ffb482c32709ed1e038500429378cA59` |
| Block | `11846649` |
| Gas | `2312553` used at `1059911686` wei effective gas price |
| Deployer | Keystore `eng156-4397-pr8-deployer`, inherited across the lane chain (eng156 → eng157 → eng158); nonce `0` before this deployment |
| Funding | 0.02 SepoliaETH, dispensed by Brioche via `wallet_dispense` (cited from predecessor eng156's HANDOFF, not independently re-traced on-chain); balance confirmed `0.02` ETH at block `11846623` (this lane's §0 gate) and still sufficient after the `2451101949194358` wei (`0.002451` ETH) spend, the receipt fee for [`0xd15d9ad598968c2c2859be78d29ccd85968904073061fcb9a96e6098bc803cb3`](https://sepolia.etherscan.io/tx/0xd15d9ad598968c2c2859be78d29ccd85968904073061fcb9a96e6098bc803cb3) |
| Explorer verification | Submit 1: `Unable to locate ContractCode`; waited 5 s. Submit 2: `Response: OK`, GUID `t9avw586f7yc3znyxwzrcacgnhzsibkubutdbwiiurqf7almq7`; status `NOTOK` "Pending in queue", then `OK` "Pass - Verified" / "Contract successfully verified". [Etherscan](https://sepolia.etherscan.io/address/0xe268c436ffb482c32709ed1e038500429378ca59) |

Predicted address (`cast compute-address`, deployer, nonce `0`), the prior
dry-run simulation, and the broadcast all agree on
`0xe268C436ffb482c32709ed1e038500429378cA59`. No second broadcast was needed.

## Constructor set and on-chain readback

Every value below was exported explicitly for the broadcast. The script's
intended/deployed check passed inside the transaction trace
(`Intended and deployed parameters agree on every field.`), and each deployed
getter was independently read from Sepolia at block `11846653`. The writer
order is part of the constructor.

| Parameter | Intended and on-chain value | Source |
| --- | --- | --- |
| `factStore` | `0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D` | ENG-4414 artifact; pinned as `SEPOLIA_FACT_STORE` in the deploy script |
| `usdc` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | ENG-4414 artifact; pinned as `SEPOLIA_USDC` in the deploy script |
| `writers[0]` Prycd | `0xfA2c254f7f4DEf5B0f3CD1D6243F52192D3fC044` | ENG-4414 artifact, writer table (order matters) |
| `writers[1]` OpenAVM | `0x70ED67c1f4FE4f5a295E5bf3CDadCF54458Da7c7` | ENG-4414 artifact, writer table |
| `writers[2]` Regrid | `0x24E52f31fc519692A814D73439BB16F44B86DfE1` | ENG-4414 artifact, writer table |
| `eligibilityWriter` | `0xa8BeCfdfD08CDd71c42cD959b6F51d73eA0EBDEF` | ENG-4414 artifact; same dedicated eligibility signer |
| `jurisdictionWriter` | `0x6a47402083D542E85e883F52607365cFD2186D6E` | Brioche ruling 661382: PROVED, not copied. This is staging.json `onchainOracleKeeper.networks.sepolia.writers.fabrica`, shown on Sepolia to have written 1 live `fabrica.fact.jurisdiction` fact (predecessor eng156 evidence, `livefact-jur2.txt` sha256 `abc5878337ffb21708ac09d890f1614e07e92fc344272f4bf13d21ca8383519c`) |
| `allowedCountry` | `"United States"` | Brioche ruling 661382 |
| `allowedCountryDigest` | `2362504821423185609` (`0x20c94d9e35139ec9`) | Proved equal to (i) the live jurisdiction fact's `countryDigest = (value >> 65) & (2^63-1)` and (ii) the deployed getter, both matching `keccak256(utf8 "fabrica.jurisdiction.country:United States") >> 193` per `src/onchain-oracle-keeper/jurisdiction-fact.ts:43-48` (fabrica-v3-api) |
| `allowedRegions` | `[]` (count `0`) | Brioche ruling 661382: empty, any region |
| `requiredEligibilityMask` | `0xF3003000` (`4076875776`) | ENG-4414 artifact; same pool eligibility gate (ENG-4327) |
| `minLiveSources` | `2` | ENG-4414 artifact |
| `maxSilence` | `259200` seconds | ENG-4414 artifact |
| `cycleCloseInterval` | `86400` seconds | ENG-4414 artifact |
| `seasoningWindow` | `86400` seconds | ENG-4414 artifact |
| `maxJumpBps` | `5000` | ENG-4414 artifact |
| `maxDispersionBps` | `30000` | ENG-4414 artifact. The script default is `20000`, so `30000` was exported explicitly (`FABRICA_AGGREGATOR_MAX_DISPERSION_BPS`) |
| `maxFirstPriceUsdc6` | `50000000000000` | ENG-4414 artifact |
| `valueCeilingUsdc6` | `50000000000000` | ENG-4414 artifact |

## Simulation and safety evidence

A fresh dry run (predecessor eng157, no `--broadcast`) at block `11846578`
printed `Chain 11155111`, `SIMULATION COMPLETE`, and `Intended and deployed
parameters agree on every field.` It estimated `3006318` total script gas
(the forge SIMULATION estimate, not a broadcast figure; the broadcast
receipt's actual `gasUsed` was `2312553`) at `2.332906595` gwei
(`0.00701345908886721` ETH), under the deployer's `0.02` ETH balance.
`cast compute-address` for that sender and nonce `0` predicted
the deployed address exactly, matching this broadcast. Gas price was checked
under the 20-gwei hold threshold immediately before this broadcast
(`1112188306` wei, ~`1.11` gwei, this lane's §0 gate at block `11846623`).
Every command pinned `--rpc-url "$SEPOLIA_RPC_URL" --chain-id 11155111`; Forge
also reads the worktree `.env`, so the shell environment alone is not a
sufficient network guard. This was the only broadcast transaction sent in this
cell (the STOP RULE — any address or readback mismatch halts the lane before
a second broadcast — was not triggered).

## Downstream scope

This deploy covers ENG-4397 PR 8's contracts half only. The API repoint (2
`config/staging.json` keys: the pool's `aggregatorReadAddress` and the new
`onchainOracleKeeper.networks.sepolia.regionAggregatorAddress`) is a separate
gated cell on a separate PR, followed by a read-only staging functional
verification once Brioche merges that PR and staging redeploys. The pool's
`priceOracleAddress` (`0x54D671dCc9B00b8c4aE40a664370D515A9FC9D9E`) is
unaffected (ENG-4447 scope).
