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
    error InvalidCanonicalUsdc(address configuredUsdc);
    error InvalidTargetPool();
    error InvalidSourceId(uint256 sourceId);
    error InvalidUint64(uint256 value);
    error InvalidMinLiveSources(uint256 minLiveSources);
    error InvalidBps(uint256 bps);
    error TargetPoolCurrencyMismatch(address poolCurrency, address configuredUsdc);
    error AggregatorNotRenounced();
    error AggregatorReadbackMismatch();

    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address internal constant MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant DEFAULTS_READER = 0x00000000000000000000000000000000FA0D0002;

    struct DeployParams {
        address factStore;
        address usdc;
        address targetPool;
        uint256 validatorId;
        uint8[] sourceIds;
        uint64 seasoningWindow;
        uint16 maxJumpBps;
        uint16 maxDispersionBps;
        uint8 minLiveSources;
    }

    function run() external returns (FabricaOracleAggregator aggregator) {
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
        DeployParams memory params = DeployParams({
            factStore: vm.envAddress("FABRICA_ATTRIBUTE_ORACLE"),
            usdc: vm.envAddress("FABRICA_LENDING_USDC"),
            targetPool: vm.envAddress("FABRICA_LENDING_TARGET_POOL"),
            validatorId: vm.envUint("FABRICA_VALIDATOR_ID"),
            sourceIds: _sourceIds(),
            seasoningWindow: seasoningWindow,
            maxJumpBps: maxJumpBps,
            maxDispersionBps: maxDispersionBps,
            minLiveSources: minLiveSources
        });
        return _deploy(params);
    }

    function _deploy(DeployParams memory params) internal returns (FabricaOracleAggregator aggregator) {
        _validateInputs(params);
        address poolCurrency = ICurrencyTokenPool(params.targetPool).currencyToken();
        if (poolCurrency != params.usdc) revert TargetPoolCurrencyMismatch(poolCurrency, params.usdc);
        _logConfig(params, poolCurrency);
        aggregator = _broadcastDeployAndRenounce(params);
        _assertRenounced(aggregator);
        _assertReadback(aggregator, params);
    }

    function _broadcastDeployAndRenounce(DeployParams memory params)
        internal
        returns (FabricaOracleAggregator aggregator)
    {
        vm.startBroadcast();
        (, address owner,) = vm.readCallers();
        if (owner == address(0)) revert InvalidBroadcastSigner();
        console2.log("Transient aggregator owner / broadcast signer:", owner);
        aggregator = new FabricaOracleAggregator(
            owner,
            params.factStore,
            params.usdc,
            params.validatorId,
            params.sourceIds,
            params.seasoningWindow,
            params.maxJumpBps,
            params.maxDispersionBps,
            params.minLiveSources
        );
        aggregator.renounceAggregator();
        vm.stopBroadcast();
    }

    function _assertRenounced(FabricaOracleAggregator aggregator) internal view {
        console2.log("FabricaOracleAggregator:", address(aggregator));
        console2.log("Renounced:", aggregator.renounced());
        console2.log("Owner:", aggregator.owner());
        if (!aggregator.renounced() || aggregator.owner() != address(0)) revert AggregatorNotRenounced();
    }

    function _logConfig(DeployParams memory params, address poolCurrency) internal view {
        console2.log("Fact store:", params.factStore);
        console2.log("USDC:", params.usdc);
        console2.log("Target pool:", params.targetPool);
        console2.log("Target pool currency:", poolCurrency);
        console2.log("Validator id:", params.validatorId);
        console2.log("Source ids:", _sourceIdsCsv(params.sourceIds));
        console2.log("Seasoning window:", params.seasoningWindow);
        console2.log("Max jump bps:", params.maxJumpBps);
        console2.log("Max dispersion bps:", params.maxDispersionBps);
        console2.log("Min live sources:", params.minLiveSources);
        console2.log("Note: minLiveSources=2 with two source ids has zero source redundancy.");
        console2.log("Aggregator owner is the broadcast signer only until renounceAggregator() in this same script.");
    }

    function _validateInputs(DeployParams memory params) internal view {
        if (params.factStore == address(0) || params.factStore.code.length == 0) revert InvalidFactStore();
        if (params.usdc == address(0) || params.usdc.code.length == 0) revert InvalidUsdc();
        _validateCanonicalUsdc(params.usdc);
        if (params.targetPool == address(0) || params.targetPool.code.length == 0) revert InvalidTargetPool();
        if (params.sourceIds.length < params.minLiveSources) revert InvalidMinLiveSources(params.minLiveSources);
    }

    function _validateCanonicalUsdc(address usdc) internal view {
        if (block.chainid == MAINNET_CHAIN_ID && usdc != MAINNET_USDC) revert InvalidCanonicalUsdc(usdc);
        if (block.chainid == SEPOLIA_CHAIN_ID && usdc != SEPOLIA_USDC) revert InvalidCanonicalUsdc(usdc);
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

    function _assertReadback(FabricaOracleAggregator aggregator, DeployParams memory params) internal view {
        if (
            address(aggregator.factStore()) != params.factStore || aggregator.usdc() != params.usdc
                || aggregator.validatorId() != params.validatorId
                || aggregator.seasoningWindow() != params.seasoningWindow
                || aggregator.maxJumpBps() != params.maxJumpBps
                || aggregator.maxDispersionBps() != params.maxDispersionBps
                || aggregator.minLiveSources() != params.minLiveSources
        ) {
            revert AggregatorReadbackMismatch();
        }
        uint8[] memory deployedSourceIds = aggregator.sourceIds();
        if (deployedSourceIds.length != params.sourceIds.length) revert AggregatorReadbackMismatch();
        for (uint256 i; i < params.sourceIds.length; ++i) {
            if (deployedSourceIds[i] != params.sourceIds[i]) revert AggregatorReadbackMismatch();
        }
    }

    function _sourceIdsCsv(uint8[] memory sourceIds) internal view returns (string memory csv) {
        if (sourceIds.length == 0) return "";
        bytes memory csvBytes;
        for (uint256 i; i < sourceIds.length; ++i) {
            if (i != 0) csvBytes = abi.encodePacked(csvBytes, ",");
            csvBytes = abi.encodePacked(csvBytes, vm.toString(sourceIds[i]));
        }
        return string(csvBytes);
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
