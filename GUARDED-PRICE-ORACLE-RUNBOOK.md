# Guarded Signed Price Oracle Runbook

This runbook covers `FabricaGuardedSignedPriceOracle`, a fresh UUPS
`IPriceOracle` implementation for future Fabrica lending-pool launches.

The MetaStreet-derived pool implementation lives in
[`fabrica-land/metastreet-contracts-v2`](https://github.com/fabrica-land/metastreet-contracts-v2).
This repository deploys only the guarded oracle contract and records the policy
needed before a future pool points at it.

## Security Model

- The oracle is a fresh UUPS proxy using `Initializable`,
  `Ownable2StepUpgradeable`, `UUPSUpgradeable`, and `EIP712Upgradeable`.
- The owner should be a Safe. The owner controls policy and authorizes upgrades.
- Quote signatures are verified with OpenZeppelin `SignatureChecker`, so the
  configured signer can be a Safe/ERC-1271 contract.
- Quotes intentionally do not include a consumed nonce. `price(...)` must remain
  `view` for the pool `IPriceOracle` interface, so replay is bounded by
  `maxQuoteAge`, `maxDuration`, per-token hard caps, reference/deviation checks,
  and Safe custody.
- The default reference freshness target is 30 days. Use a shorter
  `maxReferenceAge` if operations can reliably refresh references faster.

## Before Mainnet Liquidity

Two sibling release gates remain outside the oracle implementation PR:

1. **Pool cutover.** The existing mainnet pool
   `0x221014c0b6871f3F0d57F262ae6B5b6CD2901456` is pinned to the old oracle
   `0x3ed9E25AeBCd16860c4030692D47E0B116Ae04A5`. It must not receive launch
   liquidity. Mainnet liquidity must use a new pool configured with the guarded
   oracle.
2. **MarketplaceZone custody.** The checked mainnet and Sepolia
   `FabricaMarketplaceZone` deployments use immutable EOA signers. Moving order
   permission custody to Safe/ERC-1271 requires deploying/selecting a new Zone
   and updating marketplace order construction/configuration.

## Sepolia Deploy

Use a Foundry account/keystore or hardware-wallet account path so private-key
material is not expanded into command-line arguments. Never paste, print, or log
private keys.

<!-- markdownlint-disable MD013 -->

```bash
set -a
. ./.env
set +a

: "${SEPOLIA_RPC_URL:?set SEPOLIA_RPC_URL}"
: "${TESTNET_DEPLOYER_ACCOUNT:?set TESTNET_DEPLOYER_ACCOUNT}"
: "${EXPECTED_TESTNET_DEPLOYER:?set EXPECTED_TESTNET_DEPLOYER}"
: "${GUARDED_ORACLE_OWNER:?set GUARDED_ORACLE_OWNER}"
: "${GUARDED_ORACLE_NAME:?set GUARDED_ORACLE_NAME}"

cast wallet address --account "$TESTNET_DEPLOYER_ACCOUNT"

forge fmt --check \
  src/interfaces/IPriceOracle.sol \
  src/FabricaGuardedSignedPriceOracle.sol \
  script/FabricaGuardedSignedPriceOracleDeploy.s.sol \
  test/FabricaGuardedSignedPriceOracle.t.sol
forge build
npx -y markdownlint-cli GUARDED-PRICE-ORACLE-RUNBOOK.md

forge script \
  script/FabricaGuardedSignedPriceOracleDeploy.s.sol:FabricaGuardedSignedPriceOracleDeployScript \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --account "$TESTNET_DEPLOYER_ACCOUNT" \
  --sender "$EXPECTED_TESTNET_DEPLOYER" \
  --broadcast \
  --verify
```

<!-- markdownlint-enable MD013 -->

Before broadcasting, confirm the derived deployer address equals
`EXPECTED_TESTNET_DEPLOYER` and that this address is the expected testnet
deployer/owner for this operation. Never use a mainnet key from this agent lane.
After deployment, record the proxy address and read it back on Sepolia:

```bash
: "${GUARDED_ORACLE_PROXY:?set GUARDED_ORACLE_PROXY from the deployment log}"

cast call "$GUARDED_ORACLE_PROXY" "owner()(address)" --rpc-url "$SEPOLIA_RPC_URL"
cast call "$GUARDED_ORACLE_PROXY" "IMPLEMENTATION_VERSION()(string)" --rpc-url "$SEPOLIA_RPC_URL"
cast storage "$GUARDED_ORACLE_PROXY" \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url "$SEPOLIA_RPC_URL"
```

If `--verify` does not complete during the broadcast, verify the implementation
manually with `forge verify-contract` against the recorded implementation
address and constructor arguments for the implementation contract. The proxy
readback above remains required even if verification succeeds.

## Mainnet Boundary

Mainnet signing is operator-coordinated only. Do not source or use any mainnet
private key locally. For mainnet, prepare calldata / Safe transaction bundles
for operator review and execution.

## Safe Signer Rotation

Signer rotation is a Safe transaction:

```solidity
setSigner(collateralToken, newSafeSigner)
```

Required pre-flight:

- `newSafeSigner` is non-zero.
- `newSafeSigner.code.length > 0`; the contract rejects EOA signers.
- Safe threshold and owner set have been reviewed.
- A known-good quote signed by the new Safe validates through
  `price(collateralToken, currencyToken, ids, quantities, oracleContext)` before
  the collateral market is enabled for launch.

After execution, read back:

<!-- markdownlint-disable MD013 -->

```bash
cast call "$GUARDED_ORACLE_PROXY" \
  "collateralPolicy(address)((address,address,uint64,uint64,uint64,bool,bool))" \
  "$COLLATERAL_TOKEN" \
  --rpc-url "$SEPOLIA_RPC_URL"
```

<!-- markdownlint-enable MD013 -->

## Policy Setup

Configure collateral-wide policy:

```solidity
setSigner(collateralToken, signer)
setCollateralPolicy(collateralToken, currencyToken, maxQuoteAge, maxDuration, maxReferenceAge)
```

Configure every launch/live token:

```solidity
setTokenPolicy(
    collateralToken,
    tokenId,
    maxPrice,
    referencePrice,
    referenceUpdatedAt,
    maxDeviationBps
)
```

Enablement is the final gate and must pass the exact live tokenId list:

```solidity
setCollateralEnabled(collateralToken, true, liveTokenIds)
```

The call reverts if collateral config is missing, signer is missing, the token
list is empty, any token is missing config, or any reference is stale.

## Reference Price SLA

- Refresh `referencePrice` after every appraisal or cap-policy change.
- Refresh each active token reference at least once per `maxReferenceAge`.
- Initial recommended `maxReferenceAge`: 30 days.
- Alert before the oldest enabled token reference reaches the max age. A stale
  reference fail-closes borrows for that token until refreshed.

## Failure Triage

The contract uses distinct custom errors so operations can classify failures:

- `MissingCollateralConfig` / `MarketDisabled`
- `MissingTokenConfig`
- `QuotePriceZero`
- `QuoteDurationTooLong`
- `QuoteStale`
- `InvalidSigner`
- `QuotePriceExceedsCap`
- `ReferencePriceStale`
- `QuoteDeviationTooHigh`
- `ZeroQuantity`
- `InvalidLength`

Fail closed by default. Do not work around an oracle revert by widening policy
without Safe-reviewed reference/cap evidence.
