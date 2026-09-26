# ENG-4414 — Sepolia successor eligibility aggregator

This is the Sepolia-only successor to the Round 3 `FabricaImmutableAggregator`.
It adds the fail-closed `KIND_ELIGIBILITY` gate from ENG-4327 without changing
the Round 3 economic thresholds. No mainnet transaction was sent. The dedicated
eligibility writer completed its first fill and cycle close before this deploy
(ENG-4408).

## Deployment

| Item | Value |
| --- | --- |
| Chain | Sepolia, `11155111` |
| Contract | [`0xE3b103a39060D6DC42aC67efb9172EaD2E127cCD`](https://sepolia.etherscan.io/address/0xe3b103a39060d6dc42ac67efb9172ead2e127ccd) |
| Deploy transaction | [`0x7222ca5fe2cf8bba6635927b43f4d87b6f1847d3a60290a12bd17b3520edfa63`](https://sepolia.etherscan.io/tx/0x7222ca5fe2cf8bba6635927b43f4d87b6f1847d3a60290a12bd17b3520edfa63) |
| Receipt | `status=1`, `from=0xA1bbE76052efe8E32912b203F4195A0A891C10c8`, `to=null`, `contractAddress=0xE3b103a39060D6DC42aC67efb9172EaD2E127cCD` |
| Block | `11786921` |
| Gas | `1823302` used at `1101742479` wei effective gas price; `2008809265445658` wei spent |
| Deployer | Fresh encrypted lane keystore `eng-4414-sepolia-deployer`; nonce `0` before deployment |
| Funding | [`0xb90a941413321900cd6258430847e66ed7e3469d29be4f01c519f0ae75e4547e`](https://sepolia.etherscan.io/tx/0xb90a941413321900cd6258430847e66ed7e3469d29be4f01c519f0ae75e4547e), block `11786912`, `status=1`, `from=0x152e6102AACf29694f75Efbf424f1f017FD3813F`, `to=0xA1bbE76052efe8E32912b203F4195A0A891C10c8`, `value=0.02` SepETH |
| Explorer verification | Verify-only retry: `Pass - Verified` on Sepolia Etherscan |

The first broadcast included `--verify`, but Etherscan had not yet indexed the
contract and returned `Unable to locate ContractCode`. The deployment receipt
was already successful. `forge verify-contract` was retried without any
deployment transaction. Etherscan accepted the submission (GUID
`vpkivsm9qsiajrdticm6fv51vsjvn9gjfltn4lxjrg1iie1e72`), answered `Pending in
queue` once, then returned `Response: OK` / `Details: Pass - Verified` /
`Contract successfully verified` (captured 2026-09-26 14:57:56 UTC; the
16-line, 1880-byte output had SHA-256
`e7ba128163df665ffe8bf552cd132334c112ac913271388440f8c58f224d80fe` and was
not kept beyond the deploying lane). The
[Etherscan code page](https://sepolia.etherscan.io/address/0xe3b103a39060d6dc42ac67efb9172ead2e127ccd#code)
reads `Source Code Verified` / `Exact Match`, compiler
`v0.8.35+commit.47b9dedd`, optimization enabled with 1 run, EVM `osaka`.

## Constructor set and on-chain readback

Every value below was exported explicitly for the simulation and broadcast.
The script's intended/deployed check passed; each deployed getter was also
read independently from Sepolia. The writer order is part of the constructor.

| Parameter | Intended and on-chain value | Source |
| --- | --- | --- |
| `factStore` | `0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D` | `script/FabricaImmutableAggregatorDeploy.s.sol:57`; [ENG-4203 record](ENG-4203-round3-aggregator-pool.md) constructor table |
| `usdc` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | deploy script:42; ENG-4203 record |
| `writers[0]` Prycd | `0xfA2c254f7f4DEf5B0f3CD1D6243F52192D3fC044` | ENG-4203 record, writer table |
| `writers[1]` OpenAVM | `0x70ED67c1f4FE4f5a295E5bf3CDadCF54458Da7c7` | ENG-4203 record, writer table |
| `writers[2]` Regrid | `0x24E52f31fc519692A814D73439BB16F44B86DfE1` | ENG-4203 record, writer table |
| `eligibilityWriter` | `0xa8BeCfdfD08CDd71c42cD959b6F51d73eA0EBDEF` | ENG-4408 first-fill signer; ENG-4327 comments `f67cf29e` and `ab1a457c` require a dedicated signer distinct from the price writers |
| `requiredEligibilityMask` | `0xF3003000` (`4076875776`) | deploy script:61-83; ENG-4327 comment `f67cf29e`; Tim's comment `0e90c658` item 2 |
| `minLiveSources` | `2` | ENG-4203 record:86; unchanged by Brioche ruling 634397 |
| `maxSilence` | `259200` seconds | ENG-4203 record:87; unchanged by Brioche ruling 634397 |
| `cycleCloseInterval` | `86400` seconds | ENG-4203 record:88; unchanged by Brioche ruling 634397 |
| `seasoningWindow` | `86400` seconds | ENG-4203 record:89; unchanged by Brioche ruling 634397 |
| `maxJumpBps` | `5000` | ENG-4203 record:90; unchanged by Brioche ruling 634397 |
| `maxDispersionBps` | `30000` | ENG-4203 record:91 and Fede's ENG-3927 ruling; unchanged by Brioche ruling 634397. The script default is `20000`, so `30000` was exported explicitly. |
| `maxFirstPriceUsdc6` | `50000000000000` | ENG-4203 record:92; unchanged by Brioche ruling 634397 |
| `valueCeilingUsdc6` | `50000000000000` | ENG-4203 record:93; unchanged by Brioche ruling 634397 |

The mask requires complete two-bit pass pairs for fees in good standing (pair
6), not reported as stolen (pair 12), title valid (pair 14), and taxes current
(pair 15). `ELIGIBILITY_PAIR_COUNT` is 18; the pair order is pinned in
`src/FabricaImmutableAggregator.sol:55-71`. The price writers and eligibility
writer have no overlap, as the constructor requires.

## Simulation and safety evidence

The script was run without `--broadcast` after a Sepolia chain-id and base-fee
read. Its output said `Chain 11155111`, `SIMULATION COMPLETE`, and `Intended
and deployed parameters agree on every field.` It estimated `2370292` total
script gas. The deployer had nonce `0` and balance `0` during simulation, so
funding was not needed for the dry run. `cast compute-address` for that sender
and nonce predicted the deployed address exactly. Base fee was below the
20-gwei hold threshold before funding and before broadcast. The broadcast
again printed `Chain 11155111` and the same constructor readback. Both commands
pinned `--rpc-url "$SEPOLIA_RPC_URL" --chain-id 11155111`; Forge also reads the
worktree `.env`, so the shell environment alone is not a sufficient network
guard. The initial simulation attempt with `--verify` failed argument parsing
because `--verify` requires `--broadcast`; the valid dry run omitted it.

## Downstream scope

The API staging Round 3 pool is
`0x25dF3D8C3CEBF34a6037b3183f128d8b87275abA`. Its live pool
`priceOracle()` still returns the old Round 3 aggregator
`0x54D671dCc9B00b8c4aE40a664370D515A9FC9D9E`. The beacon currently points
to `WeightedRateERC1155CollectionPool` version `2.15`, whose external price
oracle is set only in `initialize`; the live implementation has no oracle
setter. The newer version `2.16` adds a setter but is not deployed in this
pool. This ticket repoints the staging API's oracle read to the successor and
records the API/on-chain pool mismatch in FV; Brioche owns the new-pool
follow-up. The keeper's network-level aggregator address stays on the old
Round 3 feed for the price writer.

The subgraph indexes the old aggregator address as `Round3Aggregator`; it
needs a successor data source and updated event ABI, one version bump, staging
deployment, and index verification before its PR merges. The API staging
config PR follows the subgraph PR. All stages share the Sepolia chain, so this
contract's on-chain behavior is shared even though the API configuration is
staging-specific.
