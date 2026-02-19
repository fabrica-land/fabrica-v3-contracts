# FabricaToken Upgrade Runbook

## Network Addresses

| Network | FabricaToken Proxy |
|---------|--------------------|
| Ethereum Mainnet | `0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95` |
| Sepolia | `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD` |
| Base Sepolia | `0xCE53C17A82bd67aD835d3e2ADBD3e062058B8F81` |

## Role Separation

Contracts use UUPS proxy pattern via `FabricaUUPSUpgradeable`. There are three
distinct roles, which may or may not be the same wallet:

| Role | Responsibilities |
|------|-----------------|
| **Deployer** | Deploys new implementation contracts. Can be any wallet. |
| **Proxy Admin** | Authorizes upgrades (`upgradeToAndCall`), calls reinitializers, sets new proxy admin. |
| **Owner** | Authorizes business logic (e.g., `setDefaultValidator`, `addOperatingAgreementName`). |

## Reinitializer Chain

FabricaToken has versioned initializers:

| Version | Function | Guard | Purpose |
|---------|----------|-------|---------|
| 1 | `initialize()` | `initializer` | Initial setup (ERC165, UUPS, Ownable, Pausable) |
| 2 | `initializeV2()` | `onlyProxyAdmin reinitializer(2)` | (Migration code removed — no-op) |
| 3 | `initializeV3()` | `onlyProxyAdmin reinitializer(3)` | Emits `TraitMetadataURIUpdated` |
| 4 | `initializeV4()` | `onlyProxyAdmin reinitializer(4)` | **Superseded by V5** — owner migration only (never deployed) |
| 5 | `initializeV5()` | `onlyProxyAdmin reinitializer(5)` | **OZ v4→v5 owner migration** + storage gap fix validation |

Reinitializers can be skipped — calling `initializeV5()` works whether the proxy
is currently at version 1, 2, or 3, since `reinitializer(5)` only requires the
stored version to be < 5. V4 was never deployed on any network and is superseded
by V5 which performs the same owner migration.

## OZ v4→v5 Storage Migration

The codebase upgraded from OpenZeppelin v4 to v5. OZ v5 uses ERC-7201 namespaced
storage instead of linear storage layout. This affects how state variables are
stored in the proxy's storage.

### What Changed

**Base contract storage (ERC-7201 migration):**

| Contract | OZ v4 Slot | OZ v5 ERC-7201 Slot | Migration |
|----------|-----------|---------------------|-----------|
| `OwnableUpgradeable._owner` | 101 | `0x9016d09d...9300` | **initializeV5** — reads old, writes new |
| `PausableUpgradeable._paused` | 151 | `0xcd5ed15c...3300` | Not needed — default `false` is correct |
| `Initializable._initialized` | 0 | `0xf0c57e16...6a00` | Not needed — fresh slot, reinitializer writes correctly |
| ERC-1967 (impl, admin) | Standard slots | Standard slots | Not affected — same in both versions |

**FabricaToken custom storage (slot shift — CRITICAL):**

In OZ v4, base contracts consumed 301 linear storage slots via `__gap` arrays.
In OZ v5, the same contracts use ERC-7201 namespaced storage (zero linear slots).
This caused all FabricaToken state variables to shift from slot 301+ to slot 0+,
breaking all existing proxy storage reads.

| Variable | OZ v4 Slot | Broken OZ v5 Slot | Fix |
|----------|-----------|-------------------|-----|
| `_balances` | 301 | 0 | `__legacy_gap[301]` restores original position |
| `_operatorApprovals` | 302 | 1 | (same gap fix) |
| `_property` | 303 | 2 | (same gap fix) |
| `_defaultValidator` | 304 | 3 | (same gap fix) |
| `_validatorRegistry` | 305 | 4 | (same gap fix) |
| `_contractURI` | 306 | 5 | (same gap fix) |

The fix is structural: a `uint256[301] private __legacy_gap` declared before
`_balances` pushes all variables back to their original positions. No data
migration is needed — the data was always at the correct proxy storage slots.

**OZ v4 linear storage breakdown (301 slots total):**
- Initializable: 1 slot (slot 0)
- ContextUpgradeable: `__gap[50]` (slots 1–50)
- ERC165Upgradeable: `__gap[50]` (slots 51–100)
- OwnableUpgradeable: `_owner` + `__gap[49]` (slots 101–150)
- PausableUpgradeable: `_paused` + `__gap[49]` (slots 151–200)
- ERC1967UpgradeUpgradeable: `__gap[50]` (slots 201–250)
- UUPSUpgradeable: `__gap[50]` (slots 251–300)

**WARNING:** The `__legacy_gap` is permanent and load-bearing. DO NOT remove,
resize, or reorder it in any future version. All existing proxy deployments
depend on this gap for correct storage alignment.

### Verifying Slot 101

Before running the migration on a new network, confirm the owner is at slot 101:

```bash
# Should return the expected owner address
cast storage <PROXY_ADDRESS> 101 --rpc-url <RPC_URL>

# Should return zero (OZ v5 reads from here)
cast call <PROXY_ADDRESS> "owner()(address)" --rpc-url <RPC_URL>
```

### Verifying Storage Gap Fix

After deploying the fixed implementation, verify all variables read correctly:

```bash
# _defaultValidator should return a non-zero address
cast call <PROXY_ADDRESS> "defaultValidator()(address)" --rpc-url <RPC_URL>

# _validatorRegistry should return a non-zero address
cast call <PROXY_ADDRESS> "validatorRegistry()(address)" --rpc-url <RPC_URL>

# _contractURI should return a non-empty string
cast call <PROXY_ADDRESS> "contractURI()(string)" --rpc-url <RPC_URL>

# balanceOf should return non-zero for known token holders
cast call <PROXY_ADDRESS> "balanceOf(address,uint256)(uint256)" <HOLDER_ADDRESS> <TOKEN_ID> --rpc-url <RPC_URL>
```

## Step-by-Step Upgrade Process

### Prerequisites

```bash
# Ensure .env has the required variables:
# SEPOLIA_RPC_URL, ETHERSCAN_API_KEY
# TESTNET_DEPLOYER_PRIVATE_KEY, TESTNET_PROXY_ADMIN_PRIVATE_KEY
source .env
```

### Step 1: Deploy New Implementation

Run with the **deployer** wallet (any wallet):

```bash
source .env && forge script script/FabricaTokenDeployImpl.s.sol \
  --sig "run(address)" <PROXY_ADDRESS> \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  --private-key "$TESTNET_DEPLOYER_PRIVATE_KEY"
```

Example for Sepolia:
```bash
source .env && forge script script/FabricaTokenDeployImpl.s.sol \
  --sig "run(address)" 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD \
  --rpc-url sepolia \
  --broadcast \
  --verify \
  --private-key "$TESTNET_DEPLOYER_PRIVATE_KEY"
```

Note the new implementation address from the output.

### Step 2: Upgrade Proxy

Run with the **proxy admin** wallet. Use `initializeV5()` which handles both
the owner migration and validates the storage gap fix:

```bash
source .env && forge script script/FabricaTokenUpgrade.s.sol \
  --sig "run(address,address)" <PROXY_ADDRESS> <NEW_IMPL_ADDRESS> \
  --rpc-url sepolia \
  --broadcast \
  --private-key "$TESTNET_PROXY_ADMIN_PRIVATE_KEY"
```

**Important:** Update `FabricaTokenUpgrade.s.sol` to call `initializeV5()`
instead of `initializeV4()` before running this step.

### Step 3: Verify

After the upgrade, confirm on-chain:

```bash
# Check implementation address matches
cast call <PROXY_ADDRESS> "implementation()(address)" --rpc-url sepolia

# Check proxy admin is unchanged
cast call <PROXY_ADDRESS> "proxyAdmin()(address)" --rpc-url sepolia

# Check owner is restored (NOT zero address)
cast call <PROXY_ADDRESS> "owner()(address)" --rpc-url sepolia

# Check contract is not paused
cast call <PROXY_ADDRESS> "paused()(bool)" --rpc-url sepolia

# Check storage gap fix — these should all return non-zero values
cast call <PROXY_ADDRESS> "defaultValidator()(address)" --rpc-url sepolia
cast call <PROXY_ADDRESS> "validatorRegistry()(address)" --rpc-url sepolia
cast call <PROXY_ADDRESS> "contractURI()(string)" --rpc-url sepolia
```

### If Verification Failed During Deployment

Follow up manually:

```bash
forge verify-contract <NEW_IMPL_ADDRESS> src/FabricaToken.sol:FabricaToken \
  --chain sepolia \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Adding Future Reinitializers

When adding a new reinitializer (e.g., `initializeV6`):

1. Add the function to `FabricaToken.sol` with `onlyProxyAdmin reinitializer(6)`
2. Update `FabricaTokenUpgrade.s.sol` to call the new initializer
3. Update this runbook's reinitializer chain table

## Deployment History

### Sepolia — 2025-02-12

1. Deployed new impl at `0xd4aeCe23bf3D0987A6a5AAaeCD90f0f02b074C55`
   (tx `0x87d15b179c7764a4225a86e8e2ceca76d763d88b48171543b74228d5e60459b4`)
2. Upgraded proxy with `initializeV3()` — owner migration was missing
   (tx `0xf9c8ffbf9b033b11b164da8baced39a3c966f512f1c9efc79874b077e1e6f4f8`)
3. **Owner lost** — OZ v4→v5 storage slot mismatch. Old owner at slot 101, new
   slot empty. Also: all FabricaToken state variables shifted from slot 301+ to
   slot 0+, breaking `balanceOf`, `isApprovedForAll`, `defaultValidator`, and
   all other state reads.
4. Fix: `initializeV5()` added with `__legacy_gap[301]` to restore original
   storage layout. Pending redeployment with owner migration + storage gap fix.
