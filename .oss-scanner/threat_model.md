# Threat model: Fabrica contracts

## Assets and entry points

FabricaToken records ERC-1155 ownership and validation of property tokens. The settlement contract handles ERC-20 sale proceeds and loan repayment while moving an ERC-1155 through Seaport. The lending-pool implementation belongs to a separate repository; the settlement contract calls an allowlisted pool. Review public mint, burn, settlement, oracle quote, and administrative paths for unauthorized ownership changes, loss of sale proceeds, and incorrect loan payoffs.
<!-- Source: DEPLOYMENT.md:1-14; src/FabricaToken.sol:273-333; SETTLEMENT.md:3-44 -->

## Privileged roles and signing authority

FabricaToken's owner can pause activity and change its default validator and validator registry. A UUPS proxy admin authorizes upgrades and reinitializers and can change the proxy admin; this role is distinct from the business-logic owner. The settlement owner controls its pool allowlist, pause state, and asset rescue. The guarded price oracle owner can rotate signers and set collateral policy; the configured signer authorizes quotes, including through ERC-1271 contract signatures. Review role checks and signer validation without assuming the same account holds every role.
<!-- Source: UPGRADE-RUNBOOK.md:20-38; src/FabricaToken.sol:163-187; src/FabricaUUPSUpgradeable.sol:21-54; src/FabricaSettlement.sol:193-230; GUARDED-PRICE-ORACLE-RUNBOOK.md:11-24; src/FabricaGuardedSignedPriceOracle.sol:165-243 -->

## Upgrades

The token and guarded oracle use UUPS proxies. The token's proxy admin controls upgrade authorization and versioned reinitializers, while the guarded oracle owner authorizes its upgrades. The runbook requires storage-layout care during owner migration and uses a Safe for mainnet upgrades. An implementation or initialization flaw can change asset and pricing behavior for every caller of a proxy.
<!-- Source: UPGRADE-RUNBOOK.md:20-72,98-104,366-412; GUARDED-PRICE-ORACLE-RUNBOOK.md:11-21 -->

## Oracle and external trust

The guarded oracle accepts signed prices under age, duration, per-token cap, reference, and deviation policy. Its configured signer and the policy owner are trust boundaries. Settlement depends on Seaport order validation and fulfillment, the allowlisted lending pool's repayment behavior, and Morpho flash liquidity for an under-loan sale. The pool allowlist is a security boundary; unsupported fee-on-transfer or rebasing currencies are outside its intended behavior.
<!-- Source: GUARDED-PRICE-ORACLE-RUNBOOK.md:11-24; SETTLEMENT.md:3-29,65-69,91-94 -->

## Scope

In scope: Solidity contracts under `src/`, upgrade and initialization paths, ERC-1155 mint and burn authorization, settlement accounting, oracle validation, and interactions that let an untrusted caller cross a role or asset boundary. Out of scope: the separate MetaStreet-derived lending-pool implementation, off-chain order creation, and a fault in an external protocol without an exploitable path through these contracts. Fork-dependent tests self-skip when their optional RPC setting is absent.
<!-- Source: DEPLOYMENT.md:1-14; SETTLEMENT.md:3-29; test/ForkTestBase.sol:20-43 -->

## Known accepted risks

The guarded oracle intentionally has no consumed quote nonce because `price` must remain a view call; quote age and policy bounds limit replay. A relayer's permissionless settlement can be copied with a substituted buyer, but the copier must fund the full signed price. Under-loan settlement assumes a live, sufficiently liquid, zero-fee Morpho-compatible flash provider. These are documented operating assumptions; reports should demonstrate a breach beyond them.
<!-- Source: GUARDED-PRICE-ORACLE-RUNBOOK.md:17-24; SETTLEMENT.md:23-25,102-106 -->
