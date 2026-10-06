# ENG-4447 — Sepolia successor-oracle pool

This record covers a new Sepolia pool for the successor eligibility aggregator.
The deployment transaction has **not** been broadcast. The address below is
only the result of a simulation and can change if the factory creates another
pool first. A separate broadcast approval is required.

## Approved parameters

The old pool's live getters supplied the collection, currency, durations, and
rates. The API staging roster supplied the successor aggregator address.
The design of record is ENG-4447 comment `affb6726`.

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

**PENDING BROADCAST GO.** Before sending, rerun the exact simulation and
compare the initializer hash. Record the actual address, transaction hash,
receipt status, gas used, effective gas price, and block here. Read every
new-pool getter in the table and require each value to match. Confirm factory
`isPool(newPool) == true`.

The old pool keeps its existing LP position. Brioche accepted its residual
Sepolia exposure. Cell 3 removes it from the API and Soil rosters without
redeeming the position.
