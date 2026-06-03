# Mainnet remediation: FabricaValidator `uri()` panic 0x22

**What's broken:** the mainnet default validator's `uri()` / `baseUri()` revert with Panic 0x22.
The validator was upgraded OZ v4 → v5 (block 24344085, 2026-01-30) without migrating its linear
storage, so `_baseUri` now reads slot 0 — which holds the leftover v4 `_initialized = 1` (an invalid
string length). Every FabricaToken whose validator resolves to the default validator therefore has a
broken `uri()`. Additionally, 6 pre-v5 operating-agreement names are stranded at the old slot and
return `""`.

**Fix:** a one-time `FabricaValidator.initializeV2(...)` reinitializer, run atomically inside
`upgradeToAndCall`, that (1) wipes the corrupt `_baseUri` slot and sets the correct base URI, and
(2) re-stores the 6 stranded operating-agreement names. It keeps the v5 namespaced layout (no
`__legacy_gap`), so the live v5-era `defaultOperatingAgreement` and newer agreement names are NOT
regressed. The same code + the same values (CIDs identical to Sepolia) were proven on a **mainnet
fork**: `forge test --match-test test_mainnet_upgradeFix` (see
`test/FabricaValidatorUriMainnetProbe.t.sol`).

> ⚠️ A plain `setBaseUri(...)` does NOT work — assigning over the corrupt slot also panics 0x22.
> An implementation upgrade is required. Do NOT use a `__legacy_gap` migration: it would regress the
> ~4 months of v5-era `defaultOperatingAgreement` + agreement-name writes.

## Mainnet addresses

| Thing | Address |
|---|---|
| FabricaToken proxy | `0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95` |
| Default validator proxy (target) | `0x170511f95560A1F280c29026f73a9cD6a4bA8ab0` |
| Validator owner **and** proxyAdmin (Safe) | `0x769586A65825B028b005176F1ebbd3B82bB07Fb0` |
| Current (broken) impl | `0x401f9b2260964d0cfa0ADB3F082312E2A6F7477f` |

Both `owner()` and `proxyAdmin()` are the Safe `0x769586A6…`, so **every step below is a Safe
transaction** (per `DEPLOYMENT.md`, mainnet never uses a `.env` key).

## Step 1 — Deploy the new implementation (any wallet)

The implementation holds no state and is not authorized, so it can be deployed by any deployer, then
verified on Etherscan.

```bash
forge create src/FabricaValidator.sol:FabricaValidator \
  --rpc-url mainnet --private-key <DEPLOYER> --broadcast --verify
# record the deployed address as <NEW_IMPL>
```

## Step 2 — Safe transaction: upgrade + repair (atomic)

From the Safe `0x769586A6…`, one transaction:

- **To:** `0x170511f95560A1F280c29026f73a9cD6a4bA8ab0` (validator proxy)
- **Value:** `0`
- **Method:** `upgradeToAndCall(address newImplementation, bytes data)`
  - `newImplementation` = `<NEW_IMPL>` from Step 1
  - `data` = the `initializeV2` calldata below

### `data` — `initializeV2` calldata (mainnet)

Human-readable arguments:

- `baseUri_` = `https://metadata.fabrica.land/ethereum/0x5cbeb7a0df7ed85d82a472fd56d81ed550f3ea95/`
- `strandedOperatingAgreementUris` / `…Names` (6 entries):
  | uri | name |
  |---|---|
  | `ipfs://QmRH7d7TGJ3DymLSRimjnH5cNGHzYfcvUTUA1tM9gizFY8` | `Fabrica US Trust v3.0` |
  | `ipfs://QmXRQx7wPxSwQDVVr1pTkiwvBHBUd1SYLbLgSn1Bvirqpc` | `Fabrica US Trust v3.1` |
  | `ipfs://QmcgEJkgCwizvs6Tu12jCaNMGciRNtH8dLA2TRS3aYWStX` | `Fabrica US Trust v3.2` |
  | `ipfs://Qmf6Aia6gJfRgGyGroYft3kjxsLUhJEhMYVKPKj2JwY41Z` | `Fabrica US Trust v3.3` |
  | `ipfs://QmeRZqhU59Vpn4JQvggBVQ97uMfmS68utweUury8n5JLPR` | `Fabrica US Trust v3.4` |
  | `ipfs://QmNxY3ooc4VXbW6ETd1wVAxvajZYWu81U95MmWJiNBQw14` | `Fabrica US Trust v3.5` |

Regenerate the exact bytes (source of truth):

```bash
cast calldata "initializeV2(string,string[],string[])" \
 "https://metadata.fabrica.land/ethereum/0x5cbeb7a0df7ed85d82a472fd56d81ed550f3ea95/" \
 "[ipfs://QmRH7d7TGJ3DymLSRimjnH5cNGHzYfcvUTUA1tM9gizFY8,ipfs://QmXRQx7wPxSwQDVVr1pTkiwvBHBUd1SYLbLgSn1Bvirqpc,ipfs://QmcgEJkgCwizvs6Tu12jCaNMGciRNtH8dLA2TRS3aYWStX,ipfs://Qmf6Aia6gJfRgGyGroYft3kjxsLUhJEhMYVKPKj2JwY41Z,ipfs://QmeRZqhU59Vpn4JQvggBVQ97uMfmS68utweUury8n5JLPR,ipfs://QmNxY3ooc4VXbW6ETd1wVAxvajZYWu81U95MmWJiNBQw14]" \
 "[Fabrica US Trust v3.0,Fabrica US Trust v3.1,Fabrica US Trust v3.2,Fabrica US Trust v3.3,Fabrica US Trust v3.4,Fabrica US Trust v3.5]"
```

Precomputed value (selector `0x445b6ca2`):

```
0x445b6ca2000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000005268747470733a2f2f6d657461646174612e666162726963612e6c616e642f657468657265756d2f3078356362656237613064663765643835643832613437326664353664383165643535306633656139352f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001e0000000000000000000000000000000000000000000000000000000000000024000000000000000000000000000000000000000000000000000000000000002a00000000000000000000000000000000000000000000000000000000000000035697066733a2f2f516d524837643754474a3344796d4c5352696d6a6e4835634e47487a596663765554554131744d3967697a46593800000000000000000000000000000000000000000000000000000000000000000000000000000000000035697066733a2f2f516d5852517837775078537751445656723170546b69777642484255643153594c624c67536e314276697271706300000000000000000000000000000000000000000000000000000000000000000000000000000000000035697066733a2f2f516d6367454a6b674377697a767336547531326a43614e4d476369524e744838644c41325452533361595753745800000000000000000000000000000000000000000000000000000000000000000000000000000000000035697066733a2f2f516d663641696136674a665267477947726f596674336b6a78734c55684a45684d59564b504b6a324a775934315a00000000000000000000000000000000000000000000000000000000000000000000000000000000000035697066733a2f2f516d65525a716855353956706e344a517667674256513937754d666d5336387574776555757279386e354a4c505200000000000000000000000000000000000000000000000000000000000000000000000000000000000035697066733a2f2f516d4e7859336f6f63345658625736455464317756417876616a5a59577538315539354d6d574a694e42517731340000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000015466162726963612055532054727573742076332e3000000000000000000000000000000000000000000000000000000000000000000000000000000000000015466162726963612055532054727573742076332e3100000000000000000000000000000000000000000000000000000000000000000000000000000000000015466162726963612055532054727573742076332e3200000000000000000000000000000000000000000000000000000000000000000000000000000000000015466162726963612055532054727573742076332e3300000000000000000000000000000000000000000000000000000000000000000000000000000000000015466162726963612055532054727573742076332e3400000000000000000000000000000000000000000000000000000000000000000000000000000000000015466162726963612055532054727573742076332e350000000000000000000000
```

## Step 3 — Post-upgrade verification (read-only)

```bash
V=0x170511f95560A1F280c29026f73a9cD6a4bA8ab0
cast call $V "implementation()(address)"            --rpc-url mainnet   # == <NEW_IMPL>
cast call $V "uri(uint256)(string)" 7               --rpc-url mainnet   # == baseUri + "7" (no revert)
cast call $V "baseUri()(string)"                    --rpc-url mainnet
cast call $V "defaultOperatingAgreement()(string)"  --rpc-url mainnet   # unchanged (bafkreihepeq…)
cast call $V "operatingAgreementName(string)(string)" "ipfs://QmRH7d7TGJ3DymLSRimjnH5cNGHzYfcvUTUA1tM9gizFY8" --rpc-url mainnet  # "Fabrica US Trust v3.0"
cast call $V "owner()(address)"                     --rpc-url mainnet   # unchanged (Safe)
```

## Reference: Sepolia (already shipped)

- New impl: `0x0f1Be94e9f11Bf706b5850B9a95024B3F572AE36`
- Upgrade tx: `0xe21ce04810633575fe83642b2363536ab1179819d46f7d919b9c64e98a8f48e9` (block 10982187)
- `uri(7)` now returns `https://metadata.fabrica.land/sepolia/0xb52ED2…/7`; all 6 OA names restored;
  `defaultOperatingAgreement` + v5-era names preserved.
