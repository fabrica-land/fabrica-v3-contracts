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
 */
contract FabricaLendingPoolCreateScript is Script {
    function setUp() public {}

    function run() public {
        address factory = vm.envAddress("FABRICA_LENDING_FACTORY");
        address beacon = vm.envAddress("FABRICA_LENDING_BEACON");
        address oracleProxy = vm.envAddress("FABRICA_LENDING_ORACLE");
        address currencyToken = vm.envAddress("FABRICA_LENDING_CURRENCY_TOKEN");
        address collateralToken = vm.envAddress("FABRICA_LENDING_COLLATERAL_TOKEN");
        address oracleSigner = vm.envAddress("FABRICA_LENDING_ORACLE_SIGNER");
        uint64[] memory durations = _defaultDurations();
        uint64[] memory rates = _defaultRates();
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = collateralToken;
        bytes memory params = abi.encode(
            collateralTokens,
            currencyToken,
            oracleProxy,
            durations,
            rates
        );
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
