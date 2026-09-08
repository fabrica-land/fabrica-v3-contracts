// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {FabricaImmutableAggregatorDeployScript} from "../script/FabricaImmutableAggregatorDeploy.s.sol";
import {FabricaFactStore} from "../src/FabricaFactStore.sol";
import {FabricaImmutableAggregator} from "../src/FabricaImmutableAggregator.sol";

/// @notice ENG-3925 — the deploy script's defaults, guards and intended-vs-deployed readback.
/// @dev The script is what puts immutable values on chain, so its defaults are as load-bearing as
///      the contract's own checks: a drift in `defaults()` would ship the wrong rules with every
///      other gate still green. The deploy path is driven through `runWithConfig` rather than
///      through the environment, so these assertions cannot be perturbed by whatever the operator's
///      `.env` happens to hold when the suite runs.
contract FabricaImmutableAggregatorDeployTest is Test {
    uint256 internal constant MAINNET_CHAIN_ID = 1;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    FabricaImmutableAggregatorDeployScript internal script;
    FabricaFactStore internal store;

    address internal prycd = makeAddr("deploy-writer-prycd");
    address internal openAvm = makeAddr("deploy-writer-openavm");
    address internal regrid = makeAddr("deploy-writer-regrid");

    function setUp() public {
        script = new FabricaImmutableAggregatorDeployScript();
        store = new FabricaFactStore(48);
        /* The canonical Sepolia USDC needs code for the aggregator's constructor check; off-fork it
           has none, so give it some. Nothing ever calls it. */
        vm.etch(SEPOLIA_USDC, hex"60006000fd");
        vm.chainId(SEPOLIA_CHAIN_ID);
    }

    /// @notice The script's defaults ARE Tim's numbers.
    function test_defaultsAreTimsNumbers() public view {
        (
            uint8 minLiveSources,
            uint64 maxSilence,
            uint64 cycleCloseInterval,
            uint64 seasoningWindow,
            uint16 maxJumpBps,
            uint16 maxDispersionBps,
            uint128 maxFirstPriceUsdc6,
            uint128 valueCeilingUsdc6
        ) = script.defaults();
        assertEq(minLiveSources, 2, "minimum live sources: 2 of 3");
        assertEq(maxSilence, 3 days, "maximum silence: 3 days");
        assertEq(cycleCloseInterval, 1 days, "cycle close: daily");
        assertEq(seasoningWindow, 24 hours, "seasoning: 24 hours");
        assertEq(maxJumpBps, 5000, "rate-of-change breaker, as in round 1");
        assertEq(maxDispersionBps, 20_000, "dispersion breaker, as in round 1");
        assertEq(maxFirstPriceUsdc6, 50_000_000e6, "guard 8, round-1 store default");
        assertEq(valueCeilingUsdc6, 50_000_000e6, "guard 9, round-1 store default");
        assertEq(maxSilence, 3 * cycleCloseInterval, "maximum silence is three cycle closes");
    }

    function test_deploysAndTheReadbackAgreesFieldByField() public {
        FabricaImmutableAggregator aggregator = script.runWithConfig(_config());
        assertEq(address(aggregator.factStore()), address(store), "factStore");
        assertEq(aggregator.usdc(), SEPOLIA_USDC, "usdc");
        assertEq(aggregator.writerCount(), 3, "writerCount");
        assertEq(aggregator.minLiveSources(), 2, "minLiveSources");
        assertEq(aggregator.maxSilence(), 3 days, "maxSilence");
        assertEq(aggregator.cycleCloseInterval(), 1 days, "cycleCloseInterval");
        assertEq(aggregator.seasoningWindow(), 24 hours, "seasoningWindow");
        address[] memory writers = aggregator.writers();
        assertEq(writers[0], prycd, "writer order is preserved");
        assertEq(writers[2], regrid, "writer order is preserved");
    }

    /// @notice The deployer holds nothing at any point: there is no freeze step to forget.
    function test_deployerHoldsNoPrivilegeOverTheResult() public {
        FabricaImmutableAggregator aggregator = script.runWithConfig(_config());
        (bool ownerAnswers,) = address(aggregator).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ownerAnswers, "no owner() to answer");
        (bool renounceAnswers,) = address(aggregator).staticcall(abi.encodeWithSignature("renounceAggregator()"));
        assertFalse(renounceAnswers, "nothing to renounce");
    }

    /// @notice Mainnet is refused by the script, not left to the operator's care.
    function test_refusesMainnetOutright() public {
        vm.chainId(MAINNET_CHAIN_ID);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaImmutableAggregatorDeployScript.MainnetIsNotInScope.selector, MAINNET_CHAIN_ID
            )
        );
        script.runWithConfig(_config());
    }

    function test_refusesAnyChainOtherThanSepolia() public {
        vm.chainId(8453);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaImmutableAggregatorDeployScript.UnsupportedChain.selector, uint256(8453))
        );
        script.runWithConfig(_config());
    }

    function test_refusesANonCanonicalCurrency() public {
        address impostor = makeAddr("not-sepolia-usdc");
        vm.etch(impostor, hex"60006000fd");
        FabricaImmutableAggregator.Config memory config = _config();
        config.usdc = impostor;
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaImmutableAggregatorDeployScript.NonCanonicalUsdc.selector, impostor, SEPOLIA_USDC
            )
        );
        script.runWithConfig(config);
    }

    function _config() internal view returns (FabricaImmutableAggregator.Config memory) {
        address[] memory writers = new address[](3);
        writers[0] = prycd;
        writers[1] = openAvm;
        writers[2] = regrid;
        return FabricaImmutableAggregator.Config({
            factStore: address(store),
            usdc: SEPOLIA_USDC,
            writers: writers,
            minLiveSources: 2,
            maxSilence: 3 days,
            cycleCloseInterval: 1 days,
            seasoningWindow: 24 hours,
            maxJumpBps: 5000,
            maxDispersionBps: 20_000,
            maxFirstPriceUsdc6: 50_000_000e6,
            valueCeilingUsdc6: 50_000_000e6
        });
    }
}

/// @notice ENG-3925 — the environment-driven half of the deploy script, in a contract of its own.
/// @dev `vm.setEnv` writes the PROCESS environment, and Foundry does not serialise test functions
///      within a contract, so two tests that set the same variable race and the loser reads the
///      other's value. Everything that touches the environment therefore lives here as a SINGLE
///      test function; the guard and readback assertions live in the contract above, driven through
///      `runWithConfig` so they cannot be perturbed by the operator's `.env` at all.
contract FabricaImmutableAggregatorDeployEnvTest is Test {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    function test_environmentDrivesTheDeployWithTimsNumbersAsDefaults() public {
        FabricaImmutableAggregatorDeployScript script = new FabricaImmutableAggregatorDeployScript();
        FabricaFactStore store = new FabricaFactStore(48);
        vm.etch(SEPOLIA_USDC, hex"60006000fd");
        vm.chainId(SEPOLIA_CHAIN_ID);
        address prycd = makeAddr("env-writer-prycd");
        address openAvm = makeAddr("env-writer-openavm");
        address regrid = makeAddr("env-writer-regrid");
        vm.setEnv("FABRICA_FACT_STORE", vm.toString(address(store)));
        vm.setEnv("FABRICA_LENDING_USDC", vm.toString(SEPOLIA_USDC));

        /* The writer set has no default: a guessed oracle source address would be immutable. */
        vm.setEnv("FABRICA_AGGREGATOR_WRITERS", "");
        vm.expectRevert(FabricaImmutableAggregatorDeployScript.NoWritersConfigured.selector);
        script.run();

        vm.setEnv(
            "FABRICA_AGGREGATOR_WRITERS",
            string.concat(vm.toString(prycd), ",", vm.toString(openAvm), ",", vm.toString(regrid))
        );
        FabricaImmutableAggregator aggregator = script.run();
        assertEq(address(aggregator.factStore()), address(store), "factStore from the environment");
        assertEq(aggregator.usdc(), SEPOLIA_USDC, "usdc from the environment");
        assertEq(aggregator.writerCount(), 3, "writers parsed from the environment");
        assertEq(aggregator.writers()[2], regrid, "writer order is preserved through the environment");
        assertEq(aggregator.minLiveSources(), 2, "default minimum live sources");
        assertEq(aggregator.maxSilence(), 3 days, "default maximum silence");
        assertEq(aggregator.cycleCloseInterval(), 1 days, "default cycle-close interval");
        assertEq(aggregator.seasoningWindow(), 24 hours, "default seasoning window");
        assertEq(aggregator.maxFirstPriceUsdc6(), 50_000_000e6, "default first-price cap");

        /* An override reaches the deployed bytecode, so a later ruling needs no code change. */
        vm.setEnv("FABRICA_AGGREGATOR_MAX_SILENCE", "86400");
        vm.setEnv("FABRICA_AGGREGATOR_MAX_FIRST_PRICE_USDC6", "1000000000");
        FabricaImmutableAggregator overridden = script.run();
        assertEq(overridden.maxSilence(), 1 days, "overridden maximum silence");
        assertEq(overridden.maxFirstPriceUsdc6(), 1_000e6, "overridden first-price cap");
        assertEq(overridden.seasoningWindow(), 24 hours, "an untouched default still applies");
    }
}
