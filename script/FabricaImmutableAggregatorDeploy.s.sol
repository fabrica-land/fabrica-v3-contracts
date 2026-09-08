// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FabricaImmutableAggregator} from "../src/FabricaImmutableAggregator.sol";

/// @notice ENG-3925 — deploy the round-2 immutable aggregator.
/// @dev There is no owner argument, no freeze step and no post-deploy call, which is the point of
///      the redeploy. The round-1 script (`FabricaOracleAggregatorDeployScript`) had to name a
///      transient owner, deploy, and then remember to call `renounceAggregator()` in the same
///      broadcast; a deploy that forgot the second half shipped a mutable oracle. Here the deployer
///      holds nothing at any point, so there is no window to forget.
///
///      Sepolia only. Mainnet is refused outright rather than left to the operator's care: this
///      contract is a testnet round-2 artifact and nothing about it has been through the mainnet
///      gate. The round-1 aggregator, the signed-quote pool and the ENG-3924 fact store are separate
///      deployments and are not touched, upgraded or superseded by this script.
///
///      Usage:
///        forge script script/FabricaImmutableAggregatorDeploy.s.sol:FabricaImmutableAggregatorDeployScript \
///          --rpc-url sepolia --account "$DEPLOYER_ACCOUNT" --broadcast --verifier etherscan --verify
///
///      Then create the pool with metastreet-contracts-v2's existing
///      `script/FabricaLendingPoolCreateWithAggregator.s.sol`, passing this address as
///      `FABRICA_LENDING_AGGREGATOR`. That script takes any `IPriceOracle`, so the round-2 launch
///      needs no change in that repo.
contract FabricaImmutableAggregatorDeployScript is Script {
    error MainnetIsNotInScope(uint256 chainId);
    error UnsupportedChain(uint256 chainId);
    error NonCanonicalUsdc(address configured, address expected);
    error NonCanonicalFactStore(address configured, address expected);
    error NoWritersConfigured();
    error EnvValueOutOfRange(string field, uint256 value, uint256 max);
    error IntendedVsDeployedMismatch(string field);

    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    /// @notice The live round-2 fact store (ENG-3924), pinned the way the currency is pinned.
    /// @dev Not paranoia about a typo: this store has ALREADY been redeployed once. The first
    ///      round-2 deployment at 0x89895c2fCC975c16AeAd2e213d2076dbF0aeb8b8 carried the
    ///      zero-baseline band bug, is dead, and still circulates in briefs. The aggregator's own
    ///      constructor cannot catch that mistake — it rejects a zero address, a codeless address
    ///      and a store whose `KIND_PRICE` disagrees, and the dead store passes all three — and the
    ///      readback cannot either, because it compares the deployed value against the same
    ///      configured address. Binding a pool's price feed to the wrong store is permanent here,
    ///      so the script refuses rather than trusting the environment.
    address internal constant SEPOLIA_FACT_STORE = 0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd;

    /* Tim's numbers, 2026-09-03 18:12Z, and the round-1 values ENG-3925 carries forward. These are
       DEFAULTS, not the only accepted values: each is overridable by env so a redeploy under a later
       ruling does not need a code change. The writer set has no default on purpose — the oracle
       source addresses are a Tim decision and a guessed one would be immutable. */
    uint8 internal constant DEFAULT_MIN_LIVE_SOURCES = 2;
    uint64 internal constant DEFAULT_MAX_SILENCE = 3 days;
    uint64 internal constant DEFAULT_CYCLE_CLOSE_INTERVAL = 1 days;
    uint64 internal constant DEFAULT_SEASONING_WINDOW = 24 hours;
    uint16 internal constant DEFAULT_MAX_JUMP_BPS = 5000;
    uint16 internal constant DEFAULT_MAX_DISPERSION_BPS = 20_000;
    uint128 internal constant DEFAULT_MAX_FIRST_PRICE_USDC6 = 50_000_000e6;
    uint128 internal constant DEFAULT_VALUE_CEILING_USDC6 = 50_000_000e6;

    function run() external returns (FabricaImmutableAggregator aggregator) {
        return runWithConfig(_config());
    }

    /// @notice Deploy from an explicit config rather than from the environment.
    /// @dev The environment is how the operator drives this script; an explicit config is how the
    ///      test suite drives it. Both land on this one body, so the guards and the readback that
    ///      run on Sepolia are the guards and the readback the tests exercise.
    function runWithConfig(FabricaImmutableAggregator.Config memory params)
        public
        returns (FabricaImmutableAggregator aggregator)
    {
        _validateChainCurrencyAndStore(params.usdc, params.factStore);
        _logIntended(params);
        vm.startBroadcast();
        aggregator = new FabricaImmutableAggregator(params);
        vm.stopBroadcast();
        _logDeployed(aggregator);
        _assertIntendedEqualsDeployed(aggregator, params);
        console.log("Intended and deployed parameters agree on every field.");
    }

    /// @notice Build the config the deploy will use, entirely from environment.
    /// @dev Public so the intended half of the review gate can be produced without broadcasting.
    function config() external view returns (FabricaImmutableAggregator.Config memory) {
        return _config();
    }

    /// @notice Tim's numbers, as this script will apply them when the environment does not override.
    /// @dev Exposed so the defaults are assertable without driving the environment: a silent drift
    ///      here would ship the wrong immutable rules with every other check still green.
    function defaults()
        external
        pure
        returns (
            uint8 minLiveSources,
            uint64 maxSilence,
            uint64 cycleCloseInterval,
            uint64 seasoningWindow,
            uint16 maxJumpBps,
            uint16 maxDispersionBps,
            uint128 maxFirstPriceUsdc6,
            uint128 valueCeilingUsdc6
        )
    {
        return (
            DEFAULT_MIN_LIVE_SOURCES,
            DEFAULT_MAX_SILENCE,
            DEFAULT_CYCLE_CLOSE_INTERVAL,
            DEFAULT_SEASONING_WINDOW,
            DEFAULT_MAX_JUMP_BPS,
            DEFAULT_MAX_DISPERSION_BPS,
            DEFAULT_MAX_FIRST_PRICE_USDC6,
            DEFAULT_VALUE_CEILING_USDC6
        );
    }

    function _config() internal view returns (FabricaImmutableAggregator.Config memory) {
        address[] memory writers = vm.envAddress("FABRICA_AGGREGATOR_WRITERS", ",");
        if (writers.length == 0) revert NoWritersConfigured();
        return FabricaImmutableAggregator.Config({
            factStore: vm.envAddress("FABRICA_FACT_STORE"),
            usdc: vm.envAddress("FABRICA_LENDING_USDC"),
            writers: writers,
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
            )
        });
    }

    function _validateChainCurrencyAndStore(address usdc, address factStore) internal view {
        if (block.chainid == MAINNET_CHAIN_ID) revert MainnetIsNotInScope(block.chainid);
        if (block.chainid != SEPOLIA_CHAIN_ID) revert UnsupportedChain(block.chainid);
        if (usdc != SEPOLIA_USDC) revert NonCanonicalUsdc(usdc, SEPOLIA_USDC);
        if (factStore != SEPOLIA_FACT_STORE) revert NonCanonicalFactStore(factStore, SEPOLIA_FACT_STORE);
    }

    /// @dev Every override arrives as a `uint256` and is narrowed into an immutable. Narrowing a
    ///      mistyped value silently is the worst available outcome: `MAX_JUMP_BPS=70000` would
    ///      become 4,464 and `MAX_SILENCE=2**64` would become 0, the readback would compare the
    ///      deployed value against the same truncated struct and agree, and the wrong rule would be
    ///      permanent for the life of the contract. Round 1's script carried these bounds
    ///      (`_bps`, `_uint64`, `_uint8MinLiveSources`); this restores them.
    function _bounded(string memory field, uint256 value, uint256 max) internal pure returns (uint256) {
        if (value > max) revert EnvValueOutOfRange(field, value, max);
        return value;
    }

    /// @notice The INTENDED half of the review gate ENG-3925 requires pasted into the PR.
    function _logIntended(FabricaImmutableAggregator.Config memory params) internal pure {
        console.log("=== ENG-3925 round-2 immutable aggregator: INTENDED parameters ===");
        console.log("factStore          ", params.factStore);
        console.log("usdc               ", params.usdc);
        for (uint256 i; i < params.writers.length; ++i) {
            console.log("writer             ", i, params.writers[i]);
        }
        console.log("minLiveSources     ", params.minLiveSources);
        console.log("maxSilence         ", params.maxSilence);
        console.log("cycleCloseInterval ", params.cycleCloseInterval);
        console.log("seasoningWindow    ", params.seasoningWindow);
        console.log("maxJumpBps         ", params.maxJumpBps);
        console.log("maxDispersionBps   ", params.maxDispersionBps);
        console.log("maxFirstPriceUsdc6 ", params.maxFirstPriceUsdc6);
        console.log("valueCeilingUsdc6  ", params.valueCeilingUsdc6);
    }

    /// @notice The DEPLOYED half, read back off the contract rather than echoed from the inputs.
    function _logDeployed(FabricaImmutableAggregator aggregator) internal view {
        console.log("=== ENG-3925 round-2 immutable aggregator: DEPLOYED parameters ===");
        console.log("address            ", address(aggregator));
        console.log("factStore          ", address(aggregator.factStore()));
        console.log("usdc               ", aggregator.usdc());
        address[] memory writers = aggregator.writers();
        for (uint256 i; i < writers.length; ++i) {
            console.log("writer             ", i, writers[i]);
        }
        console.log("minLiveSources     ", aggregator.minLiveSources());
        console.log("maxSilence         ", aggregator.maxSilence());
        console.log("cycleCloseInterval ", aggregator.cycleCloseInterval());
        console.log("seasoningWindow    ", aggregator.seasoningWindow());
        console.log("maxJumpBps         ", aggregator.maxJumpBps());
        console.log("maxDispersionBps   ", aggregator.maxDispersionBps());
        console.log("maxFirstPriceUsdc6 ", aggregator.maxFirstPriceUsdc6());
        console.log("valueCeilingUsdc6  ", aggregator.valueCeilingUsdc6());
        console.log("KIND_PRICE         ", vm.toString(aggregator.KIND_PRICE()));
        console.log("Ownerless by construction: no owner, no setter, no freeze step, nothing to renounce.");
    }

    /// @dev Named-field comparison so a failure says WHICH parameter drifted, not just that one did.
    function _assertIntendedEqualsDeployed(
        FabricaImmutableAggregator aggregator,
        FabricaImmutableAggregator.Config memory params
    ) internal view {
        if (address(aggregator.factStore()) != params.factStore) {
            revert IntendedVsDeployedMismatch("factStore");
        }
        if (aggregator.usdc() != params.usdc) revert IntendedVsDeployedMismatch("usdc");
        if (aggregator.minLiveSources() != params.minLiveSources) {
            revert IntendedVsDeployedMismatch("minLiveSources");
        }
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
        address[] memory deployed = aggregator.writers();
        if (deployed.length != params.writers.length) revert IntendedVsDeployedMismatch("writers.length");
        for (uint256 i; i < deployed.length; ++i) {
            if (deployed[i] != params.writers[i]) revert IntendedVsDeployedMismatch("writers");
        }
    }
}
