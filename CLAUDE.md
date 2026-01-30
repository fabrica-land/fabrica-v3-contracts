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
