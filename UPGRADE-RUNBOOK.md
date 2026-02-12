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

Reinitializers can be skipped — calling `initializeV3()` works whether the proxy
is currently at version 1 or 2, since `reinitializer(3)` only requires the
stored version to be < 3.

## Step-by-Step Upgrade Process

### Prerequisites

```bash
# Ensure .env has the required variables
# SEPOLIA_RPC_URL, ETHERSCAN_API_KEY, PRIVATE_KEY (deployer), ADMIN_PRIVATE_KEY (proxy admin)
source .env
```

### Step 1: Deploy New Implementation

Run with the **deployer** wallet (any wallet):

```bash
forge script script/FabricaTokenDeployImpl.s.sol \
  --sig "run(address)" <PROXY_ADDRESS> \
  --rpc-url sepolia \
  --broadcast \
  --verify
```

Example for Sepolia:
```bash
forge script script/FabricaTokenDeployImpl.s.sol \
  --sig "run(address)" 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD \
  --rpc-url sepolia \
  --broadcast \
  --verify
```

Note the new implementation address from the output.

### Step 2: Upgrade Proxy

Run with the **proxy admin** wallet:

```bash
forge script script/FabricaTokenUpgrade.s.sol \
  --sig "run(address,address)" <PROXY_ADDRESS> <NEW_IMPL_ADDRESS> \
  --rpc-url sepolia \
  --broadcast \
  --verify
```

This atomically upgrades the proxy and calls `initializeV3()`.

### Step 3: Verify

After the upgrade, confirm on-chain:

```bash
# Check implementation address matches
cast call <PROXY_ADDRESS> "implementation()(address)" --rpc-url sepolia

# Check proxy admin is unchanged
cast call <PROXY_ADDRESS> "proxyAdmin()(address)" --rpc-url sepolia

# Check owner is unchanged
cast call <PROXY_ADDRESS> "owner()(address)" --rpc-url sepolia
```

### If Verification Failed During Deployment

Follow up manually:

```bash
forge verify-contract <NEW_IMPL_ADDRESS> src/FabricaToken.sol:FabricaToken \
  --chain sepolia \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Adding Future Reinitializers

When adding a new reinitializer (e.g., `initializeV4`):

1. Add the function to `FabricaToken.sol` with `onlyProxyAdmin reinitializer(4)`
2. Update `FabricaTokenUpgrade.s.sol` to call the new initializer
3. Update this runbook's reinitializer chain table
