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
- **Vendored MetaStreet contracts** (`src/metastreet/**`) are vendored bit-for-bit
  from `metastreet-labs/metastreet-contracts-v2` at a pinned upstream SHA (see
  the banner at the top of each vendored file). The audit-diff story for any
  Fabrica-side change to this tree is: vendor-only commit shows the full
  upstream verbatim, subsequent commits show only the Fabrica delta. Do NOT
  modify vendored files unless absolutely necessary, and never as a
  "convenience" or import-path migration — keep modifications minimal and
  enumerated in the file's commit history.
- **Two OpenZeppelin trees coexist**: `lib/openzeppelin-contracts` (v5.3.0) for
  Fabrica's own contracts, and `lib/openzeppelin-contracts-v4` (pinned to
  v4.8.0) for the vendored MetaStreet tree. The split is enforced by the
  `src/metastreet/`-scoped remap in `remappings.txt`. This isolates upstream
  MetaStreet's OZ v4 API expectations (e.g. `security/ReentrancyGuard.sol`
  path, SafeERC20 return-value semantics) from Fabrica's contracts which
  target OZ v5. Do NOT run `git submodule update --remote
  lib/openzeppelin-contracts-v4` — the `branch = release-v4.8` entry in
  `.gitmodules` would silently advance the pin off `v4.8.0`. Use the explicit
  pinned SHA for any update.
- **MetaStreet compilation profile**: `src/metastreet/**` and `test/metastreet/**`
  compile under an `additional_compiler_profiles` entry in `foundry.toml`
  (via_ir + optimizer_runs=800 + evm_version=shanghai), mirroring upstream
  MetaStreet's hardhat config. Fabrica's own contracts continue to compile
  under the original profile so their bytecode is unaffected.
