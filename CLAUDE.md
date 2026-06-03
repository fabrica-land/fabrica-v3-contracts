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
- **MetaStreet-pool currency tokens must be fully ERC-20 compliant**
  (`transferFrom` MUST return `bool`). ENG-3076's anyone-can-repay change
  swapped `Pool.repay`'s `safeTransferFrom` for a raw `IERC20.transferFrom`
  + `require` on the new payer-pull line to fit the deployable concrete
  under EIP-170 (~770 bytes saved at that single call site). The trade-off:
  USDT-style ERC-20s whose `transferFrom` returns no value cause `Pool.repay`
  to revert on Solidity 0.8+ strict ABI decoding of empty returndata —
  borrowers using such a pool would be UNABLE TO REPAY and could only resolve
  loans through liquidation. Known unsupported: USDT on Ethereum (`0xdAC1...`),
  BNB legacy ERC-20 (`0xB8C7...`). Known supported: USDC, PYUSD, USDP, DAI,
  and most modern GENIUS Act-framework stablecoins (spot-check each via
  `cast call <token> 'transferFrom(address,address,uint256)' <a> <b> 0 --rpc-url $RPC`
  — empty returndata = unsupported, 32-byte returndata = supported). The
  operational warning lives in `script/FabricaLendingPoolCreate.s.sol` (where
  pool currency token is picked at deploy time) and in `fabrica-v3-api`'s
  `MetaStreetCurrencyTokenModel`.
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

## Shipping a live contract change or upgrade (playbook)

Required workflow for any change that ends in an on-chain deploy or proxy
upgrade (validator/token fix, new impl, etc.). Do the steps in this order — in
particular, get CI green BEFORE spending time on fork tests or deployments.

1. **Make the change and write tests** on an issue branch off `main`.
2. **Pass CI locally before fork-testing or deploying anything.** Don't burn a
   fork run or an on-chain transaction on code CI will reject. Run the same
   gates CI runs, and confirm the PR is green first:
   - `forge fmt --check` — the most common CI failure; run `forge fmt` to fix.
     (Vendored `src/fabrica-lending-pools/**` is fmt-ignored.)
   - `forge build`.
   - markdownlint on any docs you touched — tables need a blank line before and
     after (MD058); fenced code blocks need a language tag (MD040).
3. **Fork-test on every target network.** Write Foundry fork tests pinned to a
   recent block, guarded to skip when the RPC env var is absent (`vm.envOr` +
   `vm.skip`), using `vm.createSelectFork(<alias>, <block>)` so one `forge test`
   exercises mainnet AND sepolia from the `foundry.toml` rpc aliases. Assert the
   fix works AND that unrelated state does not regress. Capture raw on-chain
   evidence — verification is binary and evidence-based, no hand-waving.
4. **Ship and verify on Sepolia first.** Deploy/upgrade with the testnet keys
   (`TESTNET_*_PRIVATE_KEY`; on Sepolia owner == proxy admin == deployer EOA),
   Etherscan-verify, and confirm the live result with `cast call`.
5. **Deploy the mainnet implementation ahead of time.** Implementations are
   immutable and unprivileged (the constructor calls `_disableInitializers()`),
   so deployer identity is irrelevant and the impl is inert until the proxy
   points at it. Deploy, Etherscan-verify, and pin the concrete address.
6. **Spec the mainnet upgrade transaction — never execute it.** On mainnet the
   owner and proxy admin are a **Safe multisig** (a contract, not a key in
   `.env`). Agents must NEVER sign or submit a mainnet transaction. Produce the
   exact Safe tx (target, value, function, params/calldata), fork-test that
   exact call against the REAL deployed mainnet impl, and hand it to the
   operator + signers. One-off Safe-execution runbooks live in the Linear
   ticket, NOT in this repo (`docs/` is gitignored; the repo root is for
   evergreen runbooks only).
7. **Merge** once CI is green and human review passes.

Notes:

- Diagnose before fixing — probe the CURRENT on-chain state with raw `cast` /
  fork evidence; don't presuppose the cause.
- For OZ v4→v5 storage-migration fixes, before reaching for a `__legacy_gap`
  layout restore, check whether live data was already WRITTEN under the broken
  v5 layout. If so, a gap that points reads back at the old v4 slots will
  REGRESS that data — patch the lagging variable(s) instead (see ENG-3256: the
  validator `initializeV2` data-repair vs. the token's ENG-2764 `__legacy_gap`).
