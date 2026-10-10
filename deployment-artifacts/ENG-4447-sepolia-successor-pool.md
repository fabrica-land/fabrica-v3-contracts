# ENG-4447 — Sepolia successor-oracle pool

This record covers the new Sepolia pool for the successor eligibility aggregator.
Baguette authorized one factory transaction after the simulation. The deployed
address matched the predicted address.

## Approved parameters

The old pool's live getters supplied the collection, currency, durations, and
rates. The API staging roster supplied the successor aggregator address.
The design of record is ENG-4447 comment `affb6726`.

### Design of record (quoted)

Source: ENG-4447 comment `affb6726` by Baguette, 2026-10-06T15:00:13Z,
<https://linear.app/fabrica/issue/ENG-4447#comment-affb6726>.
The comment records the chosen path and its Brioche reference, not a
comparison of alternative designs.

Path choice:

> Path = new pool via the factory (Brioche 670487).

Parameter source:

> The old pool's live getters supplied every field except oracle. API
> `origin/main` supplied the oracle. Require exact post-deploy getter
> readback.

Residual exposure of the old pool:

> The old pool holds **40.000336 test USDC** (`USDC.balanceOf(oldPool)`).
> Leave its LP position because the share owner is unknown; remove it from
> both rosters. Direct callers can still borrow against its old oracle. To
> claim system-wide fail-closed enforcement, its LP owner must redeem and
> verify zero borrowable liquidity, or Baguette must accept that residual
> Sepolia exposure.

Open decision, the last line of the comment:

> Open decision (Brioche's, not the lane's or mine): the old pool's
> 40.000336 test USDC stays borrowable against the old oracle by direct
> callers until its LP owner redeems.

### Intended values

<!-- markdownlint-disable MD013 -->

| Field | Intended value |
| --- | --- |
| Chain ID | `11155111` (Sepolia) |
| Factory | `0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83` |
| Beacon | `0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e` |
| Existing pool | `0x25dF3D8C3CEBF34a6037b3183f128d8b87275abA` |
| Collection | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` |
| Currency | Sepolia test USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Old oracle | `0x54D671dCc9B00b8c4aE40a664370D515A9FC9D9E` |
| New oracle | `0xe268C436ffb482c32709ed1e038500429378cA59` |
| Durations, seconds | `62208000, 31104000, 23328000, 15552000, 10368000, 7776000, 5184000, 2592000` |
| Rates | `1585489599, 2219685438, 3170979198, 4122272957, 4756468797, 5390664637, 6341958396, 7927447995` |

<!-- markdownlint-enable MD013 -->

The factory initializer is
`abi.encode(address[]([collection]), currency, newOracle, durations, rates)`.
Its Keccak-256 digest is
`0x86afd9493ad7b2bc67b96c4e1faa484de9fcc531d79ed0cb4777459ea91a91a7`.
The script pins this digest and checks chain ID, code at factory, beacon, and
successor, all old-pool getters, factory registration, and all new-pool getters.
The script has no mainnet path.

## Simulation, no broadcast

The script was run on public Sepolia RPC with sender
`0x8a2f7a392f66c708133600d6f4cffafde300948a` and **without**
`--broadcast`. The public RPC's head was block `11856645` when checked after
the simulation.

```shell
forge script \
  script/Eng4447CreateSuccessorPool.s.sol:Eng4447CreateSuccessorPoolScript \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --sender 0x8a2f7a392f66c708133600d6f4cffafde300948a -vv
```

The script completed and returned simulated pool
`0x7cEcd424e48810034049a25A8320e1B18d980F02`. An independent `cast call`
of the exact `createProxied(address,bytes)` payload from the same sender returned
the same address. The script's gas estimate was `721271`; the public RPC's
`cast estimate` for the exact call returned `2563746`. Use the larger estimate
for a conservative funding check. Re-estimate before a live transaction.

## Broadcast and readback

The shared-vault wallet
`0x8a2f7a392f66c708133600d6f4cffafde300948a` submitted one Sepolia
transaction to `PoolFactory.createProxied(address,bytes)`. The submitted
900-byte calldata matched the approved simulation exactly. The pre-broadcast
simulation and `cast call` both predicted
`0x7cEcd424e48810034049a25A8320e1B18d980F02`.

| Receipt field | Observed value |
| --- | --- |
| Transaction | [`0x95dbfc57…e46b4e6`](https://sepolia.etherscan.io/tx/0x95dbfc57a3deb42f8e7a39a2beb3d405df8e49e9c9ebcf0ce820983a8e46b4e6) |
| Status | `1` |
| Block | `11856678` |
| Sender | `0x8a2f7a392f66c708133600d6f4cffafde300948a` |
| Factory | `0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83` |
| Gas used | `2521388` |
| Effective gas price | `1099713143` wei |
| Fee | `2772803522202484` wei (`0.002772803522202484` ETH) |
| Deployed pool | [`0x7cEcd424…d980F02`](https://sepolia.etherscan.io/address/0x7cEcd424e48810034049a25A8320e1B18d980F02) |

The factory's event names the deployed pool and the pinned beacon. The receipt
has no top-level `contractAddress` because the factory created the proxy
internally.

The full transaction hash is
`0x95dbfc57a3deb42f8e7a39a2beb3d405df8e49e9c9ebcf0ce820983a8e46b4e6`.
The full deployed pool address is
`0x7cEcd424e48810034049a25A8320e1B18d980F02`.

The transaction called `createProxied(beacon, params)`.
The 800 `params` bytes have the Keccak-256 digest
`0x86afd9493ad7b2bc67b96c4e1faa484de9fcc531d79ed0cb4777459ea91a91a7`.
It equals the digest that the script pins. The arguments decode to:

- beacon: `0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e`
- collections: `[0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD]`
- currency: `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`
- price oracle: `0xe268C436ffb482c32709ed1e038500429378cA59`
- durations, seconds: `62208000, 31104000, 23328000, 15552000,`
  `10368000, 7776000, 5184000, 2592000`
- rates: `1585489599, 2219685438, 3170979198, 4122272957,`
  `4756468797, 5390664637, 6341958396, 7927447995`

At receipt block `11856678`, public Sepolia RPC getter reads returned every
value in the approved parameter table:

<!-- markdownlint-disable MD013 -->

| Getter | On-chain result | Match |
| --- | --- | --- |
| `collateralToken()` | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` | Yes |
| `currencyToken()` | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | Yes |
| `priceOracle()` | `0xe268C436ffb482c32709ed1e038500429378cA59` | Yes |
| `durations()` | `62208000, 31104000, 23328000, 15552000, 10368000, 7776000, 5184000, 2592000` | Yes |
| `rates()` | `1585489599, 2219685438, 3170979198, 4122272957, 4756468797, 5390664637, 6341958396, 7927447995` | Yes |
| `admin()` | `0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83` | Yes |
| Factory `isPool(newPool)` | `true` | Yes |

<!-- markdownlint-enable MD013 -->

**Eligibility enforcement (D5).** The getter reads confirm the configured
oracle address. They do not show that the pool rejects an ineligible token. A
direct borrow call to the new pool records that check:

- token ID: `2217377156204378591`
- Sepolia block: `11866397`
- result: reverted with `CheckFailed eligibility_vacant_land`
- evidence: Vacherin `680572` cells 1 and 2 MEET. Vacherin `685099` confirms
  "Cells 1, 2 stay met".

This artifact cites that evidence. It does not re-run the borrow.

The old pool keeps its existing LP position. Brioche accepted its residual
Sepolia exposure. Cell 3 removes it from the API and Soil rosters without
redeeming the position.

## Roster activation (D4a)

The new pool `0x7cEcd424e48810034049a25A8320e1B18d980F02` is in both staging
rosters:

- API staging roster: merged PR api#2014
  (`4d6cdb6a26e180667522563796d3a503e7541f03`) adds it. Evidence: Vacherin
  `687847` API A1 MEETS.
- Soil staging roster: merged PR soil#1452
  (`0eed4b957325d80180f7e88add65c475f71be6c9`) adds it. Evidence: Vacherin
  `680572` soil cells 1 and 2.

This artifact cites those PRs and verdicts. It does not re-run them.
