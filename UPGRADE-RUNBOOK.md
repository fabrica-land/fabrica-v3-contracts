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
| 4 | `initializeV4()` | `onlyProxyAdmin reinitializer(4)` | **OZ v4→v5 owner migration** (reads slot 101, writes ERC-7201) |

Reinitializers can be skipped — calling `initializeV4()` works whether the proxy
is currently at version 1, 2, or 3, since `reinitializer(4)` only requires the
stored version to be < 4.

## OZ v4→v5 Storage Migration

The codebase upgraded from OpenZeppelin v4 to v5. OZ v5 uses ERC-7201 namespaced
storage instead of linear storage layout. This affects how state variables are
stored in the proxy's storage.

### What Changed

| Contract | OZ v4 Slot | OZ v5 ERC-7201 Slot | Migration |
|----------|-----------|---------------------|-----------|
| `OwnableUpgradeable._owner` | 101 | `0x9016d09d...9300` | **initializeV4** — reads old, writes new |
| `PausableUpgradeable._paused` | (linear) | `0xcd5ed15c...3300` | Not needed — default `false` is correct |
| `Initializable._initialized` | (linear) | `0xf0c57e16...6a00` | Not needed — fresh slot, reinitializer writes correctly |
| ERC-1967 (impl, admin) | Standard slots | Standard slots | Not affected — same in both versions |
| FabricaToken custom storage | Custom slots | Custom slots | Not affected — defined on the contract directly |

**Only `_owner` requires migration.** The paused flag defaults to `false` (not
paused), which is the correct state. The initializer version is written fresh by
the reinitializer mechanism.

### Verifying Slot 101

Before running the migration on a new network, confirm the owner is at slot 101:

```bash
# Should return the expected owner address
cast storage <PROXY_ADDRESS> 101 --rpc-url <RPC_URL>

# Should return zero (OZ v5 reads from here)
cast call <PROXY_ADDRESS> "owner()(address)" --rpc-url <RPC_URL>
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

Run with the **proxy admin** wallet:

```bash
source .env && forge script script/FabricaTokenUpgrade.s.sol \
  --sig "run(address,address)" <PROXY_ADDRESS> <NEW_IMPL_ADDRESS> \
  --rpc-url sepolia \
  --broadcast \
  --private-key "$TESTNET_PROXY_ADMIN_PRIVATE_KEY"
```

This atomically upgrades the proxy and calls `initializeV4()`, which migrates
the owner from the OZ v4 slot to the OZ v5 ERC-7201 slot.

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
```

### If Verification Failed During Deployment

Follow up manually:

```bash
forge verify-contract <NEW_IMPL_ADDRESS> src/FabricaToken.sol:FabricaToken \
  --chain sepolia \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Adding Future Reinitializers

When adding a new reinitializer (e.g., `initializeV5`):

1. Add the function to `FabricaToken.sol` with `onlyProxyAdmin reinitializer(5)`
2. Update `FabricaTokenUpgrade.s.sol` to call the new initializer
3. Update this runbook's reinitializer chain table

## Deployment History

### Sepolia — 2025-02-12

1. Deployed new impl at `0xd4aeCe23bf3D0987A6a5AAaeCD90f0f02b074C55`
   (tx `0x87d15b179c7764a4225a86e8e2ceca76d763d88b48171543b74228d5e60459b4`)
2. Upgraded proxy with `initializeV3()` — owner migration was missing
   (tx `0xf9c8ffbf9b033b11b164da8baced39a3c966f512f1c9efc79874b077e1e6f4f8`)
3. **Owner lost** — OZ v4→v5 storage gap. Old owner at slot 101, new slot empty.
4. Fix: `initializeV4()` added. Pending redeployment with owner migration.
