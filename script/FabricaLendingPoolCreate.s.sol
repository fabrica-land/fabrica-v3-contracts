// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {PoolFactory} from "../src/fabrica-lending-pools/PoolFactory.sol";
import {SimpleSignedPriceOracle} from "../src/fabrica-lending-pools/oracle/SimpleSignedPriceOracle.sol";

/**
 * @title Fabrica Lending Pool creation via PoolFactory.createProxied
 *
 * Creates a WeightedRateERC1155CollectionPool instance from existing
 * infrastructure deployed by FabricaLendingPoolStackDeploy.s.sol. The
 * pool's collateral filter is set to a single FabricaToken collection;
 * the oracle is told to expect signatures from a Fabrica-controlled
 * signer.
 *
 * Mirrors the mainnet pool 0x842ffbf1ad5314503904626122376f71603a3cf9
 * configuration verbatim (durations, rates) unless env overrides are
 * provided.
 *
 * The script registers `oracleSigner` as the SimpleSignedPriceOracle
 * signer for `collateralToken`. Caller must be the oracle's owner (the
 * deployer from FabricaLendingPoolStackDeploy).
 *
 * Required env:
 *   FABRICA_LENDING_FACTORY            PoolFactory proxy address
 *   FABRICA_LENDING_BEACON             UpgradeableBeacon address
 *   FABRICA_LENDING_ORACLE             SimpleSignedPriceOracle proxy address
 *   FABRICA_LENDING_CURRENCY_TOKEN     ERC20 currency (USDC)
 *   FABRICA_LENDING_COLLATERAL_TOKEN   FabricaToken collection address
 *   FABRICA_LENDING_ORACLE_SIGNER      EOA whose signatures the oracle will accept
 *
 * !!! CURRENCY TOKEN COMPLIANCE — READ BEFORE DEPLOYING A POOL !!!
 *
 * `FABRICA_LENDING_CURRENCY_TOKEN` MUST be a fully ERC-20-compliant token —
 * specifically, its `transferFrom(address,address,uint256)` MUST return
 * `bool` per the ERC-20 spec.
 *
 * The Fabrica-forked Pool's `repay()` path calls the currency token's
 * `transferFrom` directly (not via OpenZeppelin's SafeERC20) — this was the
 * lever that made ENG-3076 (anyone-can-repay) fit under the EIP-170 24,576-
 * byte runtime budget for `WeightedRateERC1155CollectionPool`. The trade-off
 * is that non-bool-returning ERC-20s are NOT SUPPORTED on this code path.
 *
 * Known unsupported tokens include:
 *   - Tether USDT on Ethereum (0xdAC1...) — non-standard, no return value.
 *   - BNB legacy ERC-20 (0xB8C7...) — same non-standard pattern.
 *   - Any other "USDT-style" token whose `transferFrom` signature is
 *     `function transferFrom(address,address,uint256) public` (returns
 *     nothing) rather than `returns (bool)`.
 *
 * If a pool is created with one of these as its currency token, borrowers
 * will be UNABLE TO REPAY: the bare `IERC20.transferFrom` call in `Pool.repay`
 * will revert when Solidity's strict ABI decoder fails to decode a bool from
 * the empty returndata. Loans on such a pool can only be resolved through
 * liquidation, which is a destructive outcome for the borrower.
 *
 * Supported tokens — those that return `bool` from `transferFrom`:
 *   - Circle USDC (all chains)
 *   - PayPal PYUSD
 *   - Paxos USDP
 *   - DAI (MakerDAO)
 *   - Most modern stablecoins issued under the GENIUS Act
 *     framework (verify each contract before listing — newer issuances
 *     generally conform, but spot-check before pool creation).
 *
 * Spot-check procedure for a candidate currency token:
 *   cast call <token> 'transferFrom(address,address,uint256)' \
 *     <a> <b> 0 --rpc-url $RPC
 * If returndata is `0x` (empty), the token is non-conforming and MUST NOT be
 * used. If returndata is `0x0000...00` (32-byte bool, value=false because
 * allowance=0), the token is conforming.
 *
 * Deployment (per CLAUDE.md — always include `--verify`):
 *   forge script script/FabricaLendingPoolCreate.s.sol:FabricaLendingPoolCreateScript \
 *     --rpc-url $RPC_URL --broadcast --verify
 * If verification fails during the broadcast, follow up afterward with:
 *   forge verify-contract <deployed_address> \
 *     src/fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol:WeightedRateERC1155CollectionPool \
 *     --chain <chain_id>
 */
contract FabricaLendingPoolCreateScript is Script {
    function setUp() public {}

    function run() public {
        address factory = vm.envAddress("FABRICA_LENDING_FACTORY");
        address beacon = vm.envAddress("FABRICA_LENDING_BEACON");
        address oracleProxy = vm.envAddress("FABRICA_LENDING_ORACLE");
        // !!! Must be a bool-returning ERC-20. USDT-style tokens (transferFrom
        // returns nothing) are NOT SUPPORTED — borrowers cannot repay loans
        // backed by them and would have to be liquidated. See the contract-
        // level NatSpec block above for the supported/unsupported list and the
        // cast-based spot-check procedure.
        address currencyToken = vm.envAddress("FABRICA_LENDING_CURRENCY_TOKEN");
        address collateralToken = vm.envAddress("FABRICA_LENDING_COLLATERAL_TOKEN");
        address oracleSigner = vm.envAddress("FABRICA_LENDING_ORACLE_SIGNER");
        uint64[] memory durations = _defaultDurations();
        uint64[] memory rates = _defaultRates();
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = collateralToken;
        bytes memory params = abi.encode(collateralTokens, currencyToken, oracleProxy, durations, rates);
        console.log("Factory:        ", factory);
        console.log("Beacon:         ", beacon);
        console.log("Oracle proxy:   ", oracleProxy);
        console.log("Currency token: ", currencyToken);
        console.log("Collateral:     ", collateralToken);
        console.log("Oracle signer:  ", oracleSigner);
        vm.startBroadcast();
        SimpleSignedPriceOracle(oracleProxy).setSigner(collateralToken, oracleSigner);
        address pool = PoolFactory(factory).createProxied(beacon, params);
        vm.stopBroadcast();
        console.log("=== Pool created ===");
        console.log("Pool (BeaconProxy):", pool);
    }

    /**
     * @notice Mainnet duration tiers (descending seconds): 720d, 360d, 270d,
     *         180d, 120d, 90d, 60d, 30d.
     */
    function _defaultDurations() internal pure returns (uint64[] memory durations) {
        durations = new uint64[](8);
        durations[0] = 62208000;
        durations[1] = 31104000;
        durations[2] = 23328000;
        durations[3] = 15552000;
        durations[4] = 10368000;
        durations[5] = 7776000;
        durations[6] = 5184000;
        durations[7] = 2592000;
    }

    /**
     * @notice Mainnet rate tiers (ascending APR ~5/7/10/13/15/17/20/25 %),
     *         per-second values scaled by 1e18.
     */
    function _defaultRates() internal pure returns (uint64[] memory rates) {
        rates = new uint64[](8);
        rates[0] = 1585489599;
        rates[1] = 2219685438;
        rates[2] = 3170979198;
        rates[3] = 4122272957;
        rates[4] = 4756468797;
        rates[5] = 5390664637;
        rates[6] = 6341958396;
        rates[7] = 7927447995;
    }
}
