# FabricaToken Upgrade Runbook

For the Fabrica lending pool stack and its beacon-based upgrade flow, see the
[`fabrica-land/metastreet-contracts-v2`](https://github.com/fabrica-land/metastreet-contracts-v2)
fork instead — this doc covers the FabricaToken UUPS upgrade path only.

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
| 4 | `initializeV4()` | `onlyProxyAdmin reinitializer(4)` | **OZ v4→v5 owner migration** — reads slot 101, writes ERC-7201 slot. Deployed on Sepolia 2025-02-12. |
| 5 | `initializeV5()` | `onlyProxyAdmin reinitializer(5)` | **No-op** — consumed during `__legacy_gap` storage fix upgrade. Bumps version only. |
| 6 | `initializeV6()` | `onlyProxyAdmin reinitializer(6)` | **No-op** — consumed during the ENG-3145 version-stamp rollout. Bumps version only. |

Reinitializers can be skipped — `reinitializer(N)` only requires the stored
version to be < N. Sepolia is already at V6 after the 2026-07-06 rollout, so
future implementation-only Sepolia upgrades use empty upgrade data unless a new
reinitializer is added. On mainnet and Base Sepolia, V4 must run first (owner
migration), then V5 and V6 bump the version to match the current chain.

## OZ v4→v5 Storage Migration

The codebase upgraded from OpenZeppelin v4 to v5. OZ v5 uses ERC-7201 namespaced
storage instead of linear storage layout. This affects how state variables are
stored in the proxy's storage.

### What Changed

**Base contract storage (ERC-7201 migration):**

| Contract | OZ v4 Slot | OZ v5 ERC-7201 Slot | Migration |
|----------|-----------|---------------------|-----------|
| `OwnableUpgradeable._owner` | 101 | `0x9016d09d...9300` | **initializeV4** — reads old, writes new |
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
set -a
. ./.env
set +a
: "${PROXY_ADDRESS:?set PROXY_ADDRESS}"
: "${RPC_NETWORK_NAME:?set RPC_NETWORK_NAME}"

# Should return the expected owner address
cast storage "$PROXY_ADDRESS" 101 --rpc-url "$RPC_NETWORK_NAME"

# Should return zero (OZ v5 reads from here)
cast call "$PROXY_ADDRESS" "owner()(address)" --rpc-url "$RPC_NETWORK_NAME"
```

### Verifying Storage Gap Fix

After deploying the fixed implementation, verify all variables read correctly:

```bash
set -a
. ./.env
set +a
: "${PROXY_ADDRESS:?set PROXY_ADDRESS}"
: "${HOLDER_ADDRESS:?set HOLDER_ADDRESS}"
: "${TOKEN_ID:?set TOKEN_ID}"
: "${RPC_NETWORK_NAME:?set RPC_NETWORK_NAME}"

# _defaultValidator should return a non-zero address
cast call "$PROXY_ADDRESS" "defaultValidator()(address)" --rpc-url "$RPC_NETWORK_NAME"

# _validatorRegistry should return a non-zero address
cast call "$PROXY_ADDRESS" "validatorRegistry()(address)" --rpc-url "$RPC_NETWORK_NAME"

# _contractURI should return a non-empty string
cast call "$PROXY_ADDRESS" "contractURI()(string)" --rpc-url "$RPC_NETWORK_NAME"

# balanceOf should return non-zero for known token holders
cast call "$PROXY_ADDRESS" "balanceOf(address,uint256)(uint256)" "$HOLDER_ADDRESS" "$TOKEN_ID" --rpc-url "$RPC_NETWORK_NAME"
```

## Step-by-Step Upgrade Process

### Prerequisites

```bash
# Ensure .env has the required variables:
# SEPOLIA_RPC_URL, ETHERSCAN_API_KEY
# Foundry account aliases used by --account:
# TESTNET_DEPLOYER_ACCOUNT, TESTNET_PROXY_ADMIN_ACCOUNT
# TESTNET_DEPLOYER_PRIVATE_KEY, TESTNET_PROXY_ADMIN_PRIVATE_KEY
# FOUNDRY_KEYSTORE_PASSWORD
# EXPECTED_CHAIN_ID, EXPECTED_TOKEN_PROXY, EXPECTED_TOKEN_IMPLEMENTATION,
# EXPECTED_CURRENT_IMPLEMENTATION
set -a
. ./.env
set +a
: "${TESTNET_DEPLOYER_ACCOUNT:?set TESTNET_DEPLOYER_ACCOUNT}"
: "${TESTNET_PROXY_ADMIN_ACCOUNT:?set TESTNET_PROXY_ADMIN_ACCOUNT}"
```

Use Foundry keystore accounts, hardware wallets, or a Safe flow for signing.
Do not pass raw private keys with `--private-key`; command-line arguments can
leak through shell history and process inspection. If a key must be imported
for a testnet run, install the Python account library once, then import each
testnet key into the local Foundry keystore in process. This reads from the
inherited environment and writes no key material to stdout or argv:

```bash
python3 -m pip install --user eth-account

set -a
. ./.env
set +a

python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

from eth_account import Account

def keystore_filename(value):
    if not value or value in {".", ".."} or "/" in value or "\\" in value:
        raise SystemExit("account name must be a single keystore filename")
    path = Path(value)
    if path.is_absolute() or path.name != value:
        raise SystemExit("account name must be a single keystore filename")
    return value

def write_keystore(keystore_path, keystore):
    tmp_path = None
    if keystore_path.exists():
        raise SystemExit(f"refusing to overwrite existing keystore: {keystore_path}")
    try:
        fd, tmp_name = tempfile.mkstemp(
            dir=keystore_path.parent,
            prefix=f".{keystore_path.name}.",
            suffix=".tmp",
            text=True,
        )
        tmp_path = Path(tmp_name)
        with os.fdopen(fd, "w", encoding="utf-8") as keystore_file:
            json.dump(keystore, keystore_file)
            keystore_file.flush()
            os.fsync(keystore_file.fileno())
        os.chmod(tmp_path, 0o600)
        os.link(tmp_path, keystore_path)
    finally:
        if tmp_path is not None:
            try:
                tmp_path.unlink()
            except FileNotFoundError:
                pass

password = os.environ["FOUNDRY_KEYSTORE_PASSWORD"]
accounts = [
    (os.environ["TESTNET_DEPLOYER_ACCOUNT"], os.environ["TESTNET_DEPLOYER_PRIVATE_KEY"]),
    (os.environ["TESTNET_PROXY_ADMIN_ACCOUNT"], os.environ["TESTNET_PROXY_ADMIN_PRIVATE_KEY"]),
]

keystore_dir = Path.home() / ".foundry" / "keystores"
keystore_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
for account_name, private_key in accounts:
    account_name = keystore_filename(account_name)
    keystore_path = keystore_dir / account_name
    keystore = Account.encrypt(private_key, password)
    write_keystore(keystore_path, keystore)
PY
```

### Step 1: Deploy New Implementation

Run with the **deployer** wallet (any wallet):

```bash
set -a
. ./.env
set +a
: "${PROXY_ADDRESS:?set PROXY_ADDRESS}"
: "${RPC_NETWORK_NAME:?set RPC_NETWORK_NAME}"
: "${TESTNET_DEPLOYER_ACCOUNT:?set TESTNET_DEPLOYER_ACCOUNT}"
unset TESTNET_DEPLOYER_PRIVATE_KEY TESTNET_PROXY_ADMIN_PRIVATE_KEY FOUNDRY_KEYSTORE_PASSWORD

forge script script/FabricaTokenDeployImpl.s.sol \
  --sig "run(address)" "$PROXY_ADDRESS" \
  --rpc-url "$RPC_NETWORK_NAME" \
  --broadcast \
  --verifier etherscan \
  --verify \
  --account "$TESTNET_DEPLOYER_ACCOUNT"
```

Example for Sepolia:

```bash
set -a
. ./.env
set +a
: "${TESTNET_DEPLOYER_ACCOUNT:?set TESTNET_DEPLOYER_ACCOUNT}"
unset TESTNET_DEPLOYER_PRIVATE_KEY TESTNET_PROXY_ADMIN_PRIVATE_KEY FOUNDRY_KEYSTORE_PASSWORD

forge script script/FabricaTokenDeployImpl.s.sol \
  --sig "run(address)" 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD \
  --rpc-url sepolia \
  --broadcast \
  --verifier etherscan \
  --verify \
  --account "$TESTNET_DEPLOYER_ACCOUNT"
```

Note the new implementation address from the output.

### Step 2: Upgrade Proxy

Run with the **proxy admin** wallet. The `__legacy_gap` storage fix is structural
and takes effect as soon as the new implementation is active. The initializer
called during upgrade depends on the network:

**Sepolia currently at `_initialized = 6`** (post ENG-3145 / 2026-07-06
rollout — use empty upgrade data):

```bash
set -a
. ./.env
set +a

export EXPECTED_CHAIN_ID=11155111
export EXPECTED_TOKEN_PROXY=0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD
: "${NEW_IMPL_ADDRESS:?set NEW_IMPL_ADDRESS}"
: "${CURRENT_IMPL_ADDRESS:?set CURRENT_IMPL_ADDRESS}"
: "${TESTNET_PROXY_ADMIN_ACCOUNT:?set TESTNET_PROXY_ADMIN_ACCOUNT}"
export EXPECTED_TOKEN_IMPLEMENTATION="$NEW_IMPL_ADDRESS"
export EXPECTED_CURRENT_IMPLEMENTATION="$CURRENT_IMPL_ADDRESS"
unset TESTNET_DEPLOYER_PRIVATE_KEY TESTNET_PROXY_ADMIN_PRIVATE_KEY FOUNDRY_KEYSTORE_PASSWORD
forge script script/FabricaTokenUpgrade.s.sol \
  --sig "runNoInit(address,address)" "$EXPECTED_TOKEN_PROXY" "$NEW_IMPL_ADDRESS" \
  --rpc-url sepolia \
  --broadcast \
  --account "$TESTNET_PROXY_ADMIN_ACCOUNT"
```

If a future Sepolia-like environment is still at `_initialized = 5`, use
`run(address,address)` to upgrade and call `initializeV6()`.

**Base Sepolia** (V4 not yet consumed — call V4 for owner migration, then V5
and V6 to match the current initialized version):

```bash
set -a
. ./.env
set +a

: "${CHAIN_ID:?set CHAIN_ID}"
: "${PROXY_ADDRESS:?set PROXY_ADDRESS}"
: "${NEW_IMPL_ADDRESS:?set NEW_IMPL_ADDRESS}"
: "${CURRENT_IMPL_ADDRESS:?set CURRENT_IMPL_ADDRESS}"
: "${RPC_NETWORK_NAME:?set RPC_NETWORK_NAME}"
: "${TESTNET_PROXY_ADMIN_ACCOUNT:?set TESTNET_PROXY_ADMIN_ACCOUNT}"
export EXPECTED_CHAIN_ID="$CHAIN_ID"
export EXPECTED_TOKEN_PROXY="$PROXY_ADDRESS"
export EXPECTED_TOKEN_IMPLEMENTATION="$NEW_IMPL_ADDRESS"
export EXPECTED_CURRENT_IMPLEMENTATION="$CURRENT_IMPL_ADDRESS"
unset TESTNET_DEPLOYER_PRIVATE_KEY TESTNET_PROXY_ADMIN_PRIVATE_KEY FOUNDRY_KEYSTORE_PASSWORD

# First upgrade: deploy new impl + run V4 (owner migration)
forge script script/FabricaTokenUpgrade.s.sol \
  --sig "runWithV4(address,address)" "$PROXY_ADDRESS" "$NEW_IMPL_ADDRESS" \
  --rpc-url "$RPC_NETWORK_NAME" \
  --broadcast \
  --account "$TESTNET_PROXY_ADMIN_ACCOUNT"

export EXPECTED_CURRENT_IMPLEMENTATION="$NEW_IMPL_ADDRESS"

# Then run V5 (no-op, bumps version from 4 to 5)
forge script script/FabricaTokenUpgrade.s.sol \
  --sig "runV5Only(address)" "$PROXY_ADDRESS" \
  --rpc-url "$RPC_NETWORK_NAME" \
  --broadcast \
  --account "$TESTNET_PROXY_ADMIN_ACCOUNT"

# Finally run V6 (no-op, bumps version from 5 to 6)
forge script script/FabricaTokenUpgrade.s.sol \
  --sig "runV6Only(address)" "$PROXY_ADDRESS" \
  --rpc-url "$RPC_NETWORK_NAME" \
  --broadcast \
  --account "$TESTNET_PROXY_ADMIN_ACCOUNT"
```

**Mainnet** uses the Fabrica Safe multisig. Do not broadcast from a local
account. Generate the calldata for each Safe transaction, fork-test the exact
calls, and hand target `"$PROXY_ADDRESS"`, value `0`, and the calldata to the
operator and signers:

```bash
set -a
. ./.env
set +a

: "${PROXY_ADDRESS:?set PROXY_ADDRESS}"
: "${NEW_IMPL_ADDRESS:?set NEW_IMPL_ADDRESS}"

INITIALIZE_V4_CALLDATA=$(cast calldata "initializeV4()")
UPGRADE_AND_V4_CALLDATA=$(cast calldata \
  "upgradeToAndCall(address,bytes)" \
  "$NEW_IMPL_ADDRESS" \
  "$INITIALIZE_V4_CALLDATA")
INITIALIZE_V5_CALLDATA=$(cast calldata "initializeV5()")
INITIALIZE_V6_CALLDATA=$(cast calldata "initializeV6()")

printf 'Safe tx 1 target=%s value=0 data=%s\n' "$PROXY_ADDRESS" "$UPGRADE_AND_V4_CALLDATA"
printf 'Safe tx 2 target=%s value=0 data=%s\n' "$PROXY_ADDRESS" "$INITIALIZE_V5_CALLDATA"
printf 'Safe tx 3 target=%s value=0 data=%s\n' "$PROXY_ADDRESS" "$INITIALIZE_V6_CALLDATA"
```

### Step 3: Verify

After the upgrade, confirm on-chain:

```bash
set -a
. ./.env
set +a
: "${PROXY_ADDRESS:?set PROXY_ADDRESS}"
: "${RPC_NETWORK_NAME:?set RPC_NETWORK_NAME}"

# Check implementation address matches
cast call "$PROXY_ADDRESS" "implementation()(address)" --rpc-url "$RPC_NETWORK_NAME"

# Check proxy admin is unchanged
cast call "$PROXY_ADDRESS" "proxyAdmin()(address)" --rpc-url "$RPC_NETWORK_NAME"

# Check owner is restored (NOT zero address)
cast call "$PROXY_ADDRESS" "owner()(address)" --rpc-url "$RPC_NETWORK_NAME"

# Check contract is not paused
cast call "$PROXY_ADDRESS" "paused()(bool)" --rpc-url "$RPC_NETWORK_NAME"

# Check storage gap fix — these should all return non-zero values
cast call "$PROXY_ADDRESS" "defaultValidator()(address)" --rpc-url "$RPC_NETWORK_NAME"
cast call "$PROXY_ADDRESS" "validatorRegistry()(address)" --rpc-url "$RPC_NETWORK_NAME"
cast call "$PROXY_ADDRESS" "contractURI()(string)" --rpc-url "$RPC_NETWORK_NAME"
```

### If Verification Failed During Deployment

Follow up manually:

```bash
set -a
. ./.env
set +a
: "${NEW_IMPL_ADDRESS:?set NEW_IMPL_ADDRESS}"
: "${CHAIN_NAME:?set CHAIN_NAME}"

forge verify-contract "$NEW_IMPL_ADDRESS" src/FabricaToken.sol:FabricaToken \
  --verifier etherscan \
  --chain "$CHAIN_NAME"
```

## Adding Future Reinitializers

When adding a new reinitializer after the existing V6 stamp (e.g., `initializeV7`):

1. Add the function to `FabricaToken.sol` with `onlyProxyAdmin reinitializer(7)`
2. Update `FabricaTokenUpgrade.s.sol` to call the new initializer
3. Update this runbook's reinitializer chain table

## Deployment History

### Sepolia — 2026-07-06

1. Deployed ENG-2556 `FabricaToken` implementation at
   `0x632eB7A76041B33b070213Cf11d518e84E556391`
   (tx `0x1a2c8cd3ccf8009bb1d39b59f7fa9e847baae8ee7c10aca28d1198081a2f2b3f`).
2. Upgraded Sepolia token proxy `0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD`
   with empty upgrade data because `_initialized` was already `6`
   (tx `0x31926b4329da6de191647792575de7f98f048d38f0a3d4cbfd64808e2146c31a`).
   Post-upgrade `defaultValidator` remained
   `0xAAA7FDc1A573965a2eD47Ab154332b6b55098008`.

### Sepolia — 2025-02-12

1. Deployed new impl at `0xd4aeCe23bf3D0987A6a5AAaeCD90f0f02b074C55`
   (tx `0x87d15b179c7764a4225a86e8e2ceca76d763d88b48171543b74228d5e60459b4`)
2. Upgraded proxy with `initializeV3()` + `initializeV4()`. V4 migrated _owner
   from slot 101 to OZ v5 ERC-7201 slot (`_initialized` = 4 after this).
   (tx `0xf9c8ffbf9b033b11b164da8baced39a3c966f512f1c9efc79874b077e1e6f4f8`)
3. **Storage slot shift discovered** — all FabricaToken custom state variables
   shifted from slot 301+ to slot 0+, breaking `balanceOf`, `isApprovedForAll`,
   `defaultValidator`, and all other state reads. Owner migration (V4) succeeded
   but the slot shift broke everything else.
4. Fix: `__legacy_gap[301]` added to restore original storage layout.
   `initializeV5()` and `initializeV6()` are no-op version stamps. The Sepolia
   redeployment completed on 2026-07-06 with empty upgrade data because V6 had
   already been consumed.
