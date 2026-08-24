// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FabricaOracleAggregator} from "../src/FabricaOracleAggregator.sol";

interface ICurrencyTokenPool {
    function currencyToken() external view returns (address);
}

contract FabricaOracleAggregatorDeployScript is Script {
    error InvalidBroadcastSigner();
    error DefaultsRuntimeUnavailable();
    error InvalidFactStore();
    error InvalidUsdc();
    error InvalidTargetPool();
    error InvalidSourceId(uint256 sourceId);
    error InvalidUint64(uint256 value);
    error InvalidMinLiveSources(uint256 minLiveSources);
    error InvalidBps(uint256 bps);
    error TargetPoolCurrencyMismatch(address poolCurrency, address configuredUsdc);
    error AggregatorNotRenounced();
    error AggregatorReadbackMismatch();

    address internal constant DEFAULTS_READER = 0x00000000000000000000000000000000FA0D0002;

    function run() external returns (FabricaOracleAggregator aggregator) {
        address factStore = vm.envAddress("FABRICA_ATTRIBUTE_ORACLE");
        address usdc = vm.envAddress("FABRICA_LENDING_USDC");
        address targetPool = vm.envAddress("FABRICA_LENDING_TARGET_POOL");
        uint256 validatorId = vm.envUint("FABRICA_VALIDATOR_ID");
        (
            uint64 defaultSeasoningWindow,
            uint16 defaultMaxJumpBps,
            uint16 defaultMaxDispersionBps,
            uint8 defaultMinLiveSources
        ) = _designReviewDefaultsFromContractRuntime();
        uint64 seasoningWindow =
            _uint64(vm.envOr("FABRICA_AGGREGATOR_SEASONING_WINDOW", uint256(defaultSeasoningWindow)));
        uint16 maxJumpBps = _bps(vm.envOr("FABRICA_AGGREGATOR_MAX_JUMP_BPS", uint256(defaultMaxJumpBps)));
        uint16 maxDispersionBps =
            _bps(vm.envOr("FABRICA_AGGREGATOR_MAX_DISPERSION_BPS", uint256(defaultMaxDispersionBps)));
        uint8 minLiveSources =
            _uint8MinLiveSources(vm.envOr("FABRICA_AGGREGATOR_MIN_LIVE_SOURCES", uint256(defaultMinLiveSources)));
        uint8[] memory sourceIds = _sourceIds();

        return _deploy(
            factStore,
            usdc,
            targetPool,
            validatorId,
            sourceIds,
            seasoningWindow,
            maxJumpBps,
            maxDispersionBps,
            minLiveSources
        );
    }

    function _deploy(
        address factStore,
        address usdc,
        address targetPool,
        uint256 validatorId,
        uint8[] memory sourceIds,
        uint64 seasoningWindow,
        uint16 maxJumpBps,
        uint16 maxDispersionBps,
        uint8 minLiveSources
    ) internal returns (FabricaOracleAggregator aggregator) {
        _validateInputs(factStore, usdc, targetPool, sourceIds, minLiveSources);

        address poolCurrency = ICurrencyTokenPool(targetPool).currencyToken();
        if (poolCurrency != usdc) revert TargetPoolCurrencyMismatch(poolCurrency, usdc);

        console2.log("Fact store:", factStore);
        console2.log("USDC:", usdc);
        console2.log("Target pool:", targetPool);
        console2.log("Target pool currency:", poolCurrency);
        console2.log("Validator id:", validatorId);
        console2.log("Source ids:", _sourceIdsCsv(sourceIds));
        console2.log("Seasoning window:", seasoningWindow);
        console2.log("Max jump bps:", maxJumpBps);
        console2.log("Max dispersion bps:", maxDispersionBps);
        console2.log("Min live sources:", minLiveSources);
        console2.log("Note: minLiveSources=2 with two source ids has zero source redundancy.");
        console2.log("Aggregator owner is the broadcast signer only until renounceAggregator() in this same script.");

        vm.startBroadcast();
        (, address owner,) = vm.readCallers();
        if (owner == address(0)) revert InvalidBroadcastSigner();
        console2.log("Transient aggregator owner / broadcast signer:", owner);
        aggregator = new FabricaOracleAggregator(
            owner,
            factStore,
            usdc,
            validatorId,
            sourceIds,
            seasoningWindow,
            maxJumpBps,
            maxDispersionBps,
            minLiveSources
        );
        aggregator.renounceAggregator();
        vm.stopBroadcast();

        console2.log("FabricaOracleAggregator:", address(aggregator));
        console2.log("Renounced:", aggregator.renounced());
        console2.log("Owner:", aggregator.owner());
        if (!aggregator.renounced() || aggregator.owner() != address(0)) revert AggregatorNotRenounced();
        _assertReadback(
            aggregator,
            factStore,
            usdc,
            validatorId,
            sourceIds,
            seasoningWindow,
            maxJumpBps,
            maxDispersionBps,
            minLiveSources
        );
    }

    function _validateInputs(
        address factStore,
        address usdc,
        address targetPool,
        uint8[] memory sourceIds,
        uint8 minLiveSources
    ) internal view {
        if (factStore == address(0) || factStore.code.length == 0) revert InvalidFactStore();
        if (usdc == address(0) || usdc.code.length == 0) revert InvalidUsdc();
        if (targetPool == address(0) || targetPool.code.length == 0) revert InvalidTargetPool();
        if (sourceIds.length < minLiveSources) revert InvalidMinLiveSources(minLiveSources);
    }

    function _designReviewDefaultsFromContractRuntime()
        internal
        returns (uint64 seasoningWindow, uint16 maxJumpBps, uint16 maxDispersionBps, uint8 minLiveSources)
    {
        bytes memory runtime = vm.getDeployedCode("src/FabricaOracleAggregator.sol:FabricaOracleAggregator");
        if (runtime.length == 0) revert DefaultsRuntimeUnavailable();

        vm.etch(DEFAULTS_READER, runtime);
        (seasoningWindow, maxJumpBps, maxDispersionBps, minLiveSources,,) =
            FabricaOracleAggregator(DEFAULTS_READER).designReviewDefaults();
    }

    function _sourceIds() internal view returns (uint8[] memory ids) {
        uint256[] memory configured = vm.envOr("FABRICA_AGGREGATOR_SOURCE_IDS", ",", _defaultSourceIds());
        ids = new uint8[](configured.length);
        for (uint256 i; i < configured.length; ++i) {
            if (configured[i] > type(uint8).max) revert InvalidSourceId(configured[i]);
            ids[i] = uint8(configured[i]);
        }
    }

    function _defaultSourceIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
    }

    function _assertReadback(
        FabricaOracleAggregator aggregator,
        address factStore,
        address usdc,
        uint256 validatorId,
        uint8[] memory sourceIds,
        uint64 seasoningWindow,
        uint16 maxJumpBps,
        uint16 maxDispersionBps,
        uint8 minLiveSources
    ) internal view {
        if (
            address(aggregator.factStore()) != factStore || aggregator.usdc() != usdc
                || aggregator.validatorId() != validatorId || aggregator.seasoningWindow() != seasoningWindow
                || aggregator.maxJumpBps() != maxJumpBps || aggregator.maxDispersionBps() != maxDispersionBps
                || aggregator.minLiveSources() != minLiveSources
        ) {
            revert AggregatorReadbackMismatch();
        }

        uint8[] memory deployedSourceIds = aggregator.sourceIds();
        if (deployedSourceIds.length != sourceIds.length) revert AggregatorReadbackMismatch();
        for (uint256 i; i < sourceIds.length; ++i) {
            if (deployedSourceIds[i] != sourceIds[i]) revert AggregatorReadbackMismatch();
        }
    }

    function _sourceIdsCsv(uint8[] memory sourceIds) internal view returns (string memory csv) {
        if (sourceIds.length == 0) return "";
        bytes memory out;
        for (uint256 i; i < sourceIds.length; ++i) {
            if (i != 0) out = abi.encodePacked(out, ",");
            out = abi.encodePacked(out, vm.toString(sourceIds[i]));
        }
        return string(out);
    }

    function _uint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert InvalidUint64(value);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(value);
    }

    function _bps(uint256 value) internal pure returns (uint16) {
        if (value > type(uint16).max) revert InvalidBps(value);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value);
    }

    function _uint8MinLiveSources(uint256 value) internal pure returns (uint8) {
        if (value == 0 || value > type(uint8).max) revert InvalidMinLiveSources(value);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8(value);
    }
}
