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

## Shipping a live contract change or upgrade (playbook)

Required workflow for any change that ends in an on-chain deploy or proxy
upgrade (validator/token fix, new impl, etc.). Do the steps in this order — in
particular, get CI green BEFORE spending time on fork tests or deployments.

1. **Make the change and write tests** on an issue branch off `main`.
2. **Pass CI locally before fork-testing or deploying anything.** Don't burn a
   fork run or an on-chain transaction on code CI will reject. Run the same
   gates CI runs, and confirm the PR is green first:
   - `forge fmt --check` — the most common CI failure; run `forge fmt` to fix.
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

## Measuring gas in Foundry

- Measuring several scenarios inside one test function warms storage slots,
  and EIP-2200/2929 warm-access discounts silently deflate the result. Two
  lanes hit this independently on 2026-09-03: a three-source `price()` read
  came out at 119,573 gas against a true 197,573; a `writePrice` came out 3.9x
  low.
- Guard: one scenario per test function (prime state in `setUp`, measure in
  the test), and call `vm.cool(address(contractUnderTest))` immediately before
  the measured call. The guard should change no number; if it does, the
  isolation was not holding.
- Report whole-transaction gas (21,000 intrinsic + calldata per EIP-2028 +
  execution), not execution alone, when the number is a cost. Cross-check
  against `forge test --gas-report` Min/Max; a constant small delta (~115 gas)
  is the harness call overhead, show it rather than fold it in.
- The `FabricaAttributeOracle` history ring (`historyDepth = 48`) means writes
  1-48 on a row allocate fresh slots (~20k gas/word) and write 49+ overwrite
  (~2.9k/word); state which regime a write-side number is in. Reference:
  ENG-3913 and ENG-3922 comments on Linear.
