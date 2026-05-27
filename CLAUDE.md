# Development Notes

- When deploying contracts with `forge script`, always include `--verify` to
  verify the contract on Etherscan/Basescan automatically. If verification
  fails during deployment, follow up with `forge verify-contract` afterward.
- The `.env` file contains RPC URLs and Etherscan API keys. It is not checked
  into version control. `foundry.toml` references these via environment
  variables (`${SEPOLIA_RPC_URL}`, etc.).
- Contracts use UUPS proxy pattern via `FabricaUUPSUpgradeable`. Key roles:
  - **Proxy admin**: authorizes upgrades (`upgradeToAndCall`)
  - **Owner**: authorizes business logic (e.g. `addOperatingAgreementName`)
  - These may be the same or different wallets depending on the network.
- Deployment scripts live in `script/` and are split by operation so each can
  be run with a different private key:
  - `FabricaValidatorDeployImpl.s.sol` — deploy a new implementation (any wallet)
  - `FabricaValidatorUpgrade.s.sol` — upgrade proxy to new impl (proxy admin wallet)
  - `FabricaValidatorSetDefaultOA.s.sol` — set operating agreement name/default (owner wallet)
- When upgrading a proxy from OZ v4 to OZ v5:
  - Pass `abi.encodeCall(FabricaValidator.initialize, ())` as the data argument
    to `upgradeToAndCall` so `initialize()` runs atomically during the upgrade.
  - Do NOT pass empty data — OZ v4's `upgradeToAndCall` reverts with empty data
    because it delegatecalls the new implementation's nonexistent fallback.
- When committing on an issue branch, start the commit message with the issue
  number and a space, e.g. "ENG-2428 Add validator upgrade scripts".
- **Vendored MetaStreet contracts** (`src/fabrica-lending-pools/**`) are vendored bit-for-bit
  from `metastreet-labs/metastreet-contracts-v2` at a pinned upstream SHA (see
  the banner at the top of each vendored file). The audit-diff story for any
  Fabrica-side change to this tree is: vendor-only commit shows the full
  upstream verbatim, subsequent commits show only the Fabrica delta. Do NOT
  modify vendored files unless absolutely necessary, and never as a
  "convenience" or import-path migration — keep modifications minimal and
  enumerated in the file's commit history.
- **Two OpenZeppelin trees coexist**: `lib/openzeppelin-contracts` (v5.3.0) for
  Fabrica's own contracts, and `lib/openzeppelin-contracts-v4` (pinned to
  v4.9.6) for the vendored MetaStreet tree. The split is enforced by the
  `src/fabrica-lending-pools/`-scoped remap in `remappings.txt`. This isolates upstream
  MetaStreet's OZ v4 API expectations (e.g. `security/ReentrancyGuard.sol`
  path, SafeERC20 return-value semantics) from Fabrica's contracts which
  target OZ v5. The v4.9.6 pin specifically matches upstream
  metastreet-contracts-v2's package.json at SHA 8ed467d — this is the OZ
  version mainnet's deployed pool impl was compiled against, and is what
  produces byte-equivalence with mainnet's deployed bytecode. Do NOT run
  `git submodule update --remote lib/openzeppelin-contracts-v4` — the
  `branch = release-v4.9` entry in `.gitmodules` would silently advance the
  pin off `v4.9.6`. Use the explicit pinned SHA for any update.
- **MetaStreet compilation profile**: `src/fabrica-lending-pools/**` and
  `test/fabrica-lending-pools/**` compile under an
  `additional_compiler_profiles` entry in `foundry.toml` (via_ir +
  optimizer_runs=1 + evm_version=cancun + bytecode_hash=None +
  cbor_metadata=false). runs=1 instead of upstream's runs=800 /
  per-file runs=100 because Foundry can't replicate hardhat's per-file
  overrides, and we need the smallest-bytecode setting to fit the
  WeightedRateERC1155CollectionPool concrete under EIP-170's 24576-byte
  runtime-bytecode limit with Fabrica's depositFor + anyone-can-repay
  additions on top. evm_version=cancun (rather than upstream's shanghai)
  is also load-bearing: cancun enables PUSH0 + MCOPY in via_ir codegen,
  saving ~1.3 KB on the inlined SafeERC20/IERC20 dispatch sites that
  ENG-3076 touches; with shanghai the deployable concrete blows the
  EIP-170 budget by ~1 KB. All Fabrica target chains (Ethereum mainnet,
  Sepolia, Base, Base Sepolia) are post-Dencun so cancun opcodes are
  available everywhere we deploy. CBOR metadata is stripped to save
  bytes too. Fabrica's own contracts continue to compile under the
  original profile so their bytecode is unaffected.
