# Fabrica Lending Pool Upgrade Runbook

Mirrors [`UPGRADE-RUNBOOK.md`](./UPGRADE-RUNBOOK.md) (FabricaToken) but for
the vendored MetaStreet lending pool stack in `src/fabrica-lending-pools/`.

## Network Addresses

### Sepolia

| Contract                                | Address                                      | Notes                                          |
|-----------------------------------------|----------------------------------------------|------------------------------------------------|
| **UpgradeableBeacon** (WeightedRateERC1155CollectionPool target) | `0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E` | `upgradeTo(newImpl)` is the upgrade lever      |
| **Beacon owner**                        | `0xBF03076547a99857b796717faF4034dea94569dF` | `TESTNET_DEPLOYER_PRIVATE_KEY` in `.env`       |
| **PoolFactory** (ERC1967 proxy)         | `0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83` | `createProxied(beacon, params)` spawns pools   |
| **PoolFactory owner**                   | `0xBF03076547a99857b796717faF4034dea94569dF` |                                                |
| **Pool (BeaconProxy)** — USDC + FabricaToken | `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B` | The pool with live liquidity                   |
| **ERC1155CollateralWrapper**            | `0xf6E3932F8b4ef957f3E361CECBF1489Ea93cb086` | Pool constructor immutable                     |
| **EnglishAuctionCollateralLiquidator**  | `0xc780FEe561fc6E50493C496a53c62518971ba9EF` | Pool constructor immutable                     |
| **SimpleSignedPriceOracle**             | `0x522C7F01B535b36eca6b27C32A65Ee79e7c4df45` | Per-pool oracle, set via `initialize` params   |
| **ERC20DepositTokenImplementation**     | `0x479c18dcEB406C88a0E05c86b9Ca02B6B043507B` | Pool constructor immutable                     |
| **delegate.xyz V1 registry**            | `0x00000000000076A84feF008CDAbe6409d2FE638B` | Canonical (same on all chains)                 |
| **delegate.xyz V2 registry**            | `0x00000000000000447e69651d841bD8D104Bed493` | Canonical (same on all chains)                 |
| **Currency token** (pool param)         | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | Circle USDC on Sepolia                         |
| **Collateral token** (pool param)       | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` | FabricaToken on Sepolia                        |

(Addresses sourced from the live Sepolia chain — beacon at slot
`0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50` of
the pool, factory + pool addresses cross-referenced with
[`fabrica-v3-subgraph/networks/sepolia.json`](../fabrica-v3-subgraph/networks/sepolia.json).
No broadcast logs existed in this repo prior to ENG-3076; the stack
was deployed by an earlier process. Running future
`FabricaLendingPoolStackDeploy.s.sol` / `FabricaLendingPoolUpgrade.s.sol`
under `--broadcast` will write logs to `broadcast/`.)

### Mainnet

No Fabrica-forked deployment yet. Production lending uses the upstream
MetaStreet pool at `0x842Ffbf1AD5314503904626122376f71603A3Cf9`
(`MetaStreetPoolAllTokens`, IMPLEMENTATION_VERSION 2.15, owned by
MetaStreet — not upgradable by Fabrica). Fabrica's own stack will be
deployed via `FabricaLendingPoolStackDeploy.s.sol` once the Sepolia
upgrade path is validated.

## Upgrade Pattern

Pools are deployed by `PoolFactory.createProxied(beacon, params)`, which
mints a `BeaconProxy` that delegate-calls through the beacon. Upgrading
the beacon's implementation atomically upgrades every pool created
against it. There is no per-pool upgrade; you upgrade the beacon and
every BeaconProxy sees the new code on its next call.

The upgrade is a single script (`FabricaLendingPoolUpgrade.s.sol`) that
deploys the new implementation AND calls `beacon.upgradeTo(newImpl)` in
one broadcast. Both operations are run by the beacon owner, so the
split-by-wallet pattern used for FabricaToken doesn't apply here. The
script uses `vm.deployCode` (reads the precompiled artifact) rather
than direct Solidity `new WeightedRateERC1155CollectionPool(...)` to
keep its compilation graph isolated from `FabricaLendingPoolStackDeploy.s.sol`'s
— adding a second `new` site to the project would otherwise push the
pool's runtime bytecode over EIP-170.

## Running the Upgrade

### 1. Pre-flight

```bash
# Confirm the deployer wallet still owns the beacon and that the factory
# owner agrees. If these differ from what's in this table, STOP — the
# upgrade lever is no longer in the deployer's hands.
cast call 0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E 'owner()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83 'owner()(address)' --rpc-url $SEPOLIA_RPC_URL

# Confirm the immutable args we'll bake into the new impl match the
# existing impl's. Any drift = the new impl will read wrong dependency
# addresses post-upgrade.
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'collateralLiquidator()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'delegationRegistry()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'delegationRegistryV2()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'getERC20DepositTokenImplementation()(address)' --rpc-url $SEPOLIA_RPC_URL
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'collateralWrappers()(address[])' --rpc-url $SEPOLIA_RPC_URL
```

### 2. Run the upgrade

```bash
# .env (e.g. fabrica-v3/fabrica-v3-contracts/.env) should include
# TESTNET_DEPLOYER_PRIVATE_KEY (the beacon owner), SEPOLIA_RPC_URL,
# and ETHERSCAN_API_KEY (for --verify).

export FABRICA_LENDING_BEACON=0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E
export FABRICA_LENDING_COLLATERAL_LIQUIDATOR=0xc780FEe561fc6E50493C496a53c62518971ba9EF
export FABRICA_LENDING_DELEGATE_REGISTRY_V1=0x00000000000076A84feF008CDAbe6409d2FE638B
export FABRICA_LENDING_DELEGATE_REGISTRY_V2=0x00000000000000447e69651d841bD8D104Bed493
export FABRICA_LENDING_ERC20_DEPOSIT_TOKEN_IMPL=0x479c18dcEB406C88a0E05c86b9Ca02B6B043507B
export FABRICA_LENDING_ERC1155_COLLATERAL_WRAPPER=0xf6E3932F8b4ef957f3E361CECBF1489Ea93cb086

forge script script/FabricaLendingPoolUpgrade.s.sol:FabricaLendingPoolUpgradeScript \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $TESTNET_DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify
```

Record the printed `New WeightedRateERC1155CollectionPool:` address.
The script asserts `currentImpl != newImpl` (no-op upgrade fails fast)
and asserts `beacon.implementation() == newImpl` after the call.

### 3. Post-upgrade verification

```bash
# Beacon points at the new impl
cast call 0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E 'implementation()(address)' --rpc-url $SEPOLIA_RPC_URL

# Pool BeaconProxy now sees the new IMPLEMENTATION_VERSION (set by the
# new impl's IMPLEMENTATION_VERSION constant — bump this in the next
# vendored-tree commit if you want it visible)
cast call 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B 'IMPLEMENTATION_VERSION()(string)' --rpc-url $SEPOLIA_RPC_URL

# Functional check (ENG-3076): anyone can repay.
#   1. Borrow against a FabricaToken to mint a loan receipt.
#   2. Have a non-borrower address (with USDC + allowance) call repay() with that receipt.
#   3. Verify msg.sender's USDC was pulled and the borrower received their collateral.
# See MetaStreetPoolRepaySepoliaFork.t.sol for the exact assertion shape.
```

## Upgrade History

| Date | Network | Impl Address | Notes |
|------|---------|--------------|-------|
| (initial deploy, pre-broadcast-log) | Sepolia | `0x890625c28d221B65e97D300d2BC0F305D12acDCf` | Upstream MetaStreet `WeightedRateERC1155CollectionPool` 2.15. No Fabrica modifications. |
| 2026-05-27 (ENG-3076) | Sepolia | `0xA84C15ecA620C5E4766fE0c6dd8Eaf419A838518` | Adds `Pool.depositFor(recipient, ...)` (ENG-3101) and anyone-can-repay (ENG-3076). EIP-170: 24,259 bytes (317 under). Deployed via the original FabricaLendingPoolStackDeploy.s.sol's `new WeightedRateERC1155CollectionPool(...)` site (broadcast tx `0x38efda31d7f12fe780d9a31e5b7bec0c74d15040829868de4265bbb38820bbc5`); beacon repointed via `UpgradeableBeacon.upgradeTo` shortly after. Subsequent upgrades use `FabricaLendingPoolUpgrade.s.sol` (one-shot deploy + repoint). [Etherscan-verified](https://sepolia.etherscan.io/address/0xA84C15ecA620C5E4766fE0c6dd8Eaf419A838518#code). |

### Live verification (Sepolia, 2026-05-27)

Functional smoke against the LIVE upgraded pool — third-party repay
exercised the new code path end-to-end with no config change to Soil
or the API (pool address `0x6C56d0953377D7AB479BBA85Da8d61050F774c0B`
is the unchanged BeaconProxy).

| Assertion | Before tx | After tx | ✓ |
|---|---|---|---|
| Loan status | 1 (Active) | 2 (Repaid) | ✓ |
| Staging-API-wallet USDC | 17,127,900 | 16,126,156 | -1,001,744 raw USDC pulled from third party (NOT the borrower) |
| Original borrower USDC | 5,999,554 | 5,999,554 | unchanged — borrower paid nothing |
| Borrower holds collateral | 0 | 1 | collateral returned to original borrower |
| Pool holds collateral | 1 | 0 | pool released collateral |

- Loan receipt hash: `0x7c60c27cf5176aedcd005825842f4a2c84ae4e33e45b6b6cfd0c5129ce957934`
- Original borrower: `0xadd5a1b8f83cad37120dc0c80af29cd42406e7a6`
- Third-party caller (the staging API `mintingWallet`): `0x5Cf573087BB00d56b457C108F373a3ac4984e28b`
- Collateral: FabricaToken id `6916740955630765930`
- Repay tx: [`0x90e99cfddfd2ec8ec7afabb8084d2f943a82a944b4f4a07b74bd6183456ed59a`](https://sepolia.etherscan.io/tx/0x90e99cfddfd2ec8ec7afabb8084d2f943a82a944b4f4a07b74bd6183456ed59a)
