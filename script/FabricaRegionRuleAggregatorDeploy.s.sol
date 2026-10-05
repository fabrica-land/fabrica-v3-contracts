// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FabricaRegionRuleAggregator} from "../src/FabricaRegionRuleAggregator.sol";

/// @notice Deploy the region rule aggregator (ENG-4397). Modeled on
///         `FabricaImmutableAggregatorDeploy.s.sol`: an env-driven config builder, a chain-id
///         guard that refuses mainnet outright, and a post-deploy intended-vs-deployed readback
///         so a mismatch between the env this ran with and the bytecode that landed on chain is
///         a revert, not a silent gap.
/// @dev Sepolia only, same reasoning as the immutable aggregator: this is a testnet artifact and
///      nothing about it has cleared the mainnet gate.
///
///      Usage:
///        forge script script/FabricaRegionRuleAggregatorDeploy.s.sol:FabricaRegionRuleAggregatorDeployScript \
///          --rpc-url sepolia --account "$DEPLOYER_ACCOUNT" --broadcast --verifier etherscan --verify
contract FabricaRegionRuleAggregatorDeployScript is Script {
    error MainnetIsNotInScope(uint256 chainId);
    error UnsupportedChain(uint256 chainId);
    error NonCanonicalUsdc(address configured, address expected);
    error NonCanonicalFactStore(address configured, address expected);
    error NonCanonicalEligibilityMask(uint128 configured, uint128 expected);
    error NoWritersConfigured();
    error EnvValueOutOfRange(string field, uint256 value, uint256 max);
    error IntendedVsDeployedMismatch(string field);

    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    /// @notice The live round-3 fact store (ENG-4203), pinned the same way
    ///         `FabricaImmutableAggregatorDeploy.s.sol` pins it, for the same reason: this store has
    ///         been redeployed twice and a stale address still circulates in briefs.
    address internal constant SEPOLIA_FACT_STORE = 0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D;

    /// @notice The eligibility pairs the pool's off-chain signed quote gates on, as the required
    ///         mask. Same value and same provenance as `FabricaImmutableAggregatorDeploy.s.sol`
    ///         (ENG-4327, Tim 2026-09-24): this aggregator's `eligibilityReport` answers the same
    ///         eligibility question for the same pool, so it is bound to the same mask rather than
    ///         a second, independently-reviewed one.
    uint128 internal constant REQUIRED_ELIGIBILITY_MASK = 0xF3003000;

    /* Defaults carried forward from `FabricaImmutableAggregatorDeploy.s.sol` (Tim's numbers,
       2026-09-03 18:12Z). These are DEFAULTS, not the only accepted values: each is overridable by
       env so this deploy's actual values (per the ENG-4397 ruling) do not need a code change. The
       writer set, the eligibility writer and the jurisdiction writer have no default on purpose —
       oracle source identity is a Tim decision and a guessed one would be immutable. */
    uint8 internal constant DEFAULT_MIN_LIVE_SOURCES = 2;
    uint64 internal constant DEFAULT_MAX_SILENCE = 3 days;
    uint64 internal constant DEFAULT_CYCLE_CLOSE_INTERVAL = 1 days;
    uint64 internal constant DEFAULT_SEASONING_WINDOW = 24 hours;
    uint16 internal constant DEFAULT_MAX_JUMP_BPS = 5000;
    uint16 internal constant DEFAULT_MAX_DISPERSION_BPS = 20_000;
    uint128 internal constant DEFAULT_MAX_FIRST_PRICE_USDC6 = 50_000_000e6;
    uint128 internal constant DEFAULT_VALUE_CEILING_USDC6 = 50_000_000e6;

    /// @notice The jurisdiction rule this deploy enforces (Brioche ruling, ENG-4397): no region
    ///         restriction, country gated to the US. Fixed here rather than env-driven for the same
    ///         reason `REQUIRED_ELIGIBILITY_MASK` is fixed above: the rule is a reviewed decision,
    ///         not an operator knob.
    string internal constant ALLOWED_COUNTRY = "United States";

    function run() external returns (FabricaRegionRuleAggregator aggregator) {
        return runWithConfig(_config());
    }

    /// @notice Deploy from an explicit config rather than from the environment.
    /// @dev The environment is how the operator drives this script; an explicit config is how the
    ///      test suite drives it. Both land on this one body, so the guards and the readback that
    ///      run on Sepolia are the guards and the readback the tests exercise.
    function runWithConfig(FabricaRegionRuleAggregator.Config memory params)
        public
        returns (FabricaRegionRuleAggregator aggregator)
    {
        _validateChainCurrencyAndStore(params.usdc, params.factStore);
        _requireCanonicalEligibilityMask(params.requiredEligibilityMask);
        _logIntended(params);
        vm.startBroadcast();
        aggregator = new FabricaRegionRuleAggregator(params);
        vm.stopBroadcast();
        _logDeployed(aggregator);
        _assertIntendedEqualsDeployed(aggregator, params);
        console.log("Intended and deployed parameters agree on every field.");
    }

    function _config() internal view returns (FabricaRegionRuleAggregator.Config memory) {
        address[] memory writers = vm.envAddress("FABRICA_AGGREGATOR_WRITERS", ",");
        if (writers.length == 0) revert NoWritersConfigured();
        string[] memory allowedRegions = new string[](0);
        return FabricaRegionRuleAggregator.Config({
            factStore: vm.envAddress("FABRICA_FACT_STORE"),
            usdc: vm.envAddress("FABRICA_LENDING_USDC"),
            writers: writers,
            eligibilityWriter: vm.envAddress("FABRICA_ELIGIBILITY_WRITER"),
            requiredEligibilityMask: REQUIRED_ELIGIBILITY_MASK,
            minLiveSources: uint8(
                _bounded(
                    "minLiveSources",
                    vm.envOr("FABRICA_AGGREGATOR_MIN_LIVE_SOURCES", uint256(DEFAULT_MIN_LIVE_SOURCES)),
                    type(uint8).max
                )
            ),
            maxSilence: uint64(
                _bounded(
                    "maxSilence",
                    vm.envOr("FABRICA_AGGREGATOR_MAX_SILENCE", uint256(DEFAULT_MAX_SILENCE)),
                    type(uint64).max
                )
            ),
            cycleCloseInterval: uint64(
                _bounded(
                    "cycleCloseInterval",
                    vm.envOr("FABRICA_AGGREGATOR_CYCLE_CLOSE_INTERVAL", uint256(DEFAULT_CYCLE_CLOSE_INTERVAL)),
                    type(uint64).max
                )
            ),
            seasoningWindow: uint64(
                _bounded(
                    "seasoningWindow",
                    vm.envOr("FABRICA_AGGREGATOR_SEASONING_WINDOW", uint256(DEFAULT_SEASONING_WINDOW)),
                    type(uint64).max
                )
            ),
            maxJumpBps: uint16(
                _bounded(
                    "maxJumpBps",
                    vm.envOr("FABRICA_AGGREGATOR_MAX_JUMP_BPS", uint256(DEFAULT_MAX_JUMP_BPS)),
                    type(uint16).max
                )
            ),
            maxDispersionBps: uint16(
                _bounded(
                    "maxDispersionBps",
                    vm.envOr("FABRICA_AGGREGATOR_MAX_DISPERSION_BPS", uint256(DEFAULT_MAX_DISPERSION_BPS)),
                    type(uint16).max
                )
            ),
            maxFirstPriceUsdc6: uint128(
                _bounded(
                    "maxFirstPriceUsdc6",
                    vm.envOr("FABRICA_AGGREGATOR_MAX_FIRST_PRICE_USDC6", uint256(DEFAULT_MAX_FIRST_PRICE_USDC6)),
                    type(uint128).max
                )
            ),
            valueCeilingUsdc6: uint128(
                _bounded(
                    "valueCeilingUsdc6",
                    vm.envOr("FABRICA_AGGREGATOR_VALUE_CEILING_USDC6", uint256(DEFAULT_VALUE_CEILING_USDC6)),
                    type(uint128).max
                )
            ),
            jurisdictionWriter: vm.envAddress("FABRICA_JURISDICTION_WRITER"),
            allowedCountry: ALLOWED_COUNTRY,
            allowedRegions: allowedRegions
        });
    }

    function _validateChainCurrencyAndStore(address usdc, address factStore) internal view {
        if (block.chainid == MAINNET_CHAIN_ID) revert MainnetIsNotInScope(block.chainid);
        if (block.chainid != SEPOLIA_CHAIN_ID) revert UnsupportedChain(block.chainid);
        if (usdc != SEPOLIA_USDC) revert NonCanonicalUsdc(usdc, SEPOLIA_USDC);
        if (factStore != SEPOLIA_FACT_STORE) revert NonCanonicalFactStore(factStore, SEPOLIA_FACT_STORE);
    }

    function _requireCanonicalEligibilityMask(uint128 configured) internal pure {
        if (configured != REQUIRED_ELIGIBILITY_MASK) {
            revert NonCanonicalEligibilityMask(configured, REQUIRED_ELIGIBILITY_MASK);
        }
    }

    function _bounded(string memory field, uint256 value, uint256 max) internal pure returns (uint256) {
        if (value > max) revert EnvValueOutOfRange(field, value, max);
        return value;
    }

    function _logIntended(FabricaRegionRuleAggregator.Config memory params) internal pure {
        console.log("Intended factStore:", params.factStore);
        console.log("Intended usdc:", params.usdc);
        console.log("Intended writer count:", params.writers.length);
        for (uint256 i = 0; i < params.writers.length; i++) {
            console.log("Intended writer:", params.writers[i]);
        }
        console.log("Intended eligibilityWriter:", params.eligibilityWriter);
        console.log("Intended jurisdictionWriter:", params.jurisdictionWriter);
        console.log("Intended allowedCountry:", params.allowedCountry);
        console.log("Intended allowedRegions count:", params.allowedRegions.length);
        console.log("Intended requiredEligibilityMask:", params.requiredEligibilityMask);
        console.log("Intended minLiveSources:", params.minLiveSources);
        console.log("Intended maxSilence:", params.maxSilence);
        console.log("Intended cycleCloseInterval:", params.cycleCloseInterval);
        console.log("Intended seasoningWindow:", params.seasoningWindow);
        console.log("Intended maxJumpBps:", params.maxJumpBps);
        console.log("Intended maxDispersionBps:", params.maxDispersionBps);
        console.log("Intended maxFirstPriceUsdc6:", params.maxFirstPriceUsdc6);
        console.log("Intended valueCeilingUsdc6:", params.valueCeilingUsdc6);
    }

    function _logDeployed(FabricaRegionRuleAggregator aggregator) internal view {
        console.log("Deployed address:", address(aggregator));
        console.log("Deployed factStore:", address(aggregator.factStore()));
        console.log("Deployed usdc:", aggregator.usdc());
        console.log("Deployed writerCount:", aggregator.writerCount());
        console.log("Deployed eligibilityWriter:", aggregator.eligibilityWriter());
        console.log("Deployed jurisdictionWriter:", aggregator.jurisdictionWriter());
        console.log("Deployed allowedCountryDigest:", aggregator.allowedCountryDigest());
        console.log("Deployed allowedRegionCount:", aggregator.allowedRegionCount());
        console.log("Deployed requiredEligibilityMask:", aggregator.requiredEligibilityMask());
        console.log("Deployed minLiveSources:", aggregator.minLiveSources());
        console.log("Deployed maxSilence:", aggregator.maxSilence());
        console.log("Deployed cycleCloseInterval:", aggregator.cycleCloseInterval());
        console.log("Deployed seasoningWindow:", aggregator.seasoningWindow());
        console.log("Deployed maxJumpBps:", aggregator.maxJumpBps());
        console.log("Deployed maxDispersionBps:", aggregator.maxDispersionBps());
        console.log("Deployed maxFirstPriceUsdc6:", aggregator.maxFirstPriceUsdc6());
        console.log("Deployed valueCeilingUsdc6:", aggregator.valueCeilingUsdc6());
    }

    function _assertIntendedEqualsDeployed(
        FabricaRegionRuleAggregator aggregator,
        FabricaRegionRuleAggregator.Config memory params
    ) internal view {
        if (address(aggregator.factStore()) != params.factStore) {
            revert IntendedVsDeployedMismatch("factStore");
        }
        if (aggregator.usdc() != params.usdc) revert IntendedVsDeployedMismatch("usdc");
        if (aggregator.writerCount() != params.writers.length) revert IntendedVsDeployedMismatch("writerCount");
        address[] memory deployedWriters = aggregator.writers();
        for (uint256 i = 0; i < params.writers.length; i++) {
            if (deployedWriters[i] != params.writers[i]) revert IntendedVsDeployedMismatch("writers");
        }
        if (aggregator.eligibilityWriter() != params.eligibilityWriter) {
            revert IntendedVsDeployedMismatch("eligibilityWriter");
        }
        if (aggregator.jurisdictionWriter() != params.jurisdictionWriter) {
            revert IntendedVsDeployedMismatch("jurisdictionWriter");
        }
        if (aggregator.allowedRegionCount() != params.allowedRegions.length) {
            revert IntendedVsDeployedMismatch("allowedRegionCount");
        }
        if (aggregator.requiredEligibilityMask() != params.requiredEligibilityMask) {
            revert IntendedVsDeployedMismatch("requiredEligibilityMask");
        }
        if (aggregator.minLiveSources() != params.minLiveSources) revert IntendedVsDeployedMismatch("minLiveSources");
        if (aggregator.maxSilence() != params.maxSilence) revert IntendedVsDeployedMismatch("maxSilence");
        if (aggregator.cycleCloseInterval() != params.cycleCloseInterval) {
            revert IntendedVsDeployedMismatch("cycleCloseInterval");
        }
        if (aggregator.seasoningWindow() != params.seasoningWindow) {
            revert IntendedVsDeployedMismatch("seasoningWindow");
        }
        if (aggregator.maxJumpBps() != params.maxJumpBps) revert IntendedVsDeployedMismatch("maxJumpBps");
        if (aggregator.maxDispersionBps() != params.maxDispersionBps) {
            revert IntendedVsDeployedMismatch("maxDispersionBps");
        }
        if (aggregator.maxFirstPriceUsdc6() != params.maxFirstPriceUsdc6) {
            revert IntendedVsDeployedMismatch("maxFirstPriceUsdc6");
        }
        if (aggregator.valueCeilingUsdc6() != params.valueCeilingUsdc6) {
            revert IntendedVsDeployedMismatch("valueCeilingUsdc6");
        }
    }
}
