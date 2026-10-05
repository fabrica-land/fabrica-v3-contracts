// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaRegionRuleAggregator} from "../src/FabricaRegionRuleAggregator.sol";
import {FabricaRegionRuleAggregatorDeployScript} from "../script/FabricaRegionRuleAggregatorDeploy.s.sol";

/// @notice Fork tests for the ENG-4397 region aggregator deploy script, mirroring the pattern
///         CLAUDE.md's "Shipping a live contract change" playbook asks for: a real Sepolia fork,
///         pinned to a recent block, skipped (not failed) when no RPC is configured.
contract FabricaRegionRuleAggregatorDeployTest is Test {
    FabricaRegionRuleAggregatorDeployScript internal script;

    address internal constant SEPOLIA_FACT_STORE = 0x97fC2C3A41d4DB570363C5e3425C3676E4B81c5D;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant PRYCD_WRITER = 0xfA2c254f7f4DEf5B0f3CD1D6243F52192D3fC044;
    address internal constant OPENAVM_WRITER = 0x70ED67c1f4FE4f5a295E5bf3CDadCF54458Da7c7;
    address internal constant REGRID_WRITER = 0x24E52f31fc519692A814D73439BB16F44B86DfE1;
    address internal constant ELIGIBILITY_WRITER = 0xa8BeCfdfD08CDd71c42cD959b6F51d73eA0EBDEF;
    address internal constant JURISDICTION_WRITER = 0x6a47402083D542E85e883F52607365cFD2186D6E;
    uint128 internal constant REQUIRED_ELIGIBILITY_MASK = 0xF3003000;
    uint256 internal constant SEPOLIA_FORK_BLOCK = 11_845_363;

    /// @dev The fork must be selected BEFORE the script is deployed: `createSelectFork` switches
    ///      the active chain state, and a contract deployed on the pre-fork (local anvil) chain has
    ///      no code on the forked chain. Selecting the fork first, then deploying, matches the
    ///      pattern `Eng3925ImmutableAggregatorSepoliaFork.t.sol` documents ("The fork is created
    ///      and pinned by the inherited setUp").
    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        if (bytes(rpc).length != 0) {
            vm.createSelectFork(rpc, SEPOLIA_FORK_BLOCK);
        }
        script = new FabricaRegionRuleAggregatorDeployScript();
    }

    function _liveConfig() internal pure returns (FabricaRegionRuleAggregator.Config memory config) {
        address[] memory writers = new address[](3);
        writers[0] = PRYCD_WRITER;
        writers[1] = OPENAVM_WRITER;
        writers[2] = REGRID_WRITER;
        string[] memory allowedRegions = new string[](0);
        config = FabricaRegionRuleAggregator.Config({
            factStore: SEPOLIA_FACT_STORE,
            usdc: SEPOLIA_USDC,
            writers: writers,
            eligibilityWriter: ELIGIBILITY_WRITER,
            requiredEligibilityMask: REQUIRED_ELIGIBILITY_MASK,
            minLiveSources: 2,
            maxSilence: 259_200,
            cycleCloseInterval: 86_400,
            seasoningWindow: 86_400,
            maxJumpBps: 5000,
            maxDispersionBps: 30_000,
            maxFirstPriceUsdc6: 50_000_000e6,
            valueCeilingUsdc6: 50_000_000e6,
            jurisdictionWriter: JURISDICTION_WRITER,
            allowedCountry: "United States",
            allowedRegions: allowedRegions
        });
    }

    function test_runWithConfig_deploysAndMatchesIntended() public {
        FabricaRegionRuleAggregator.Config memory config = _liveConfig();
        FabricaRegionRuleAggregator aggregator = script.runWithConfig(config);

        assertEq(address(aggregator.factStore()), config.factStore);
        assertEq(aggregator.usdc(), config.usdc);
        assertEq(aggregator.writerCount(), config.writers.length);
        address[] memory deployedWriters = aggregator.writers();
        for (uint256 i = 0; i < config.writers.length; i++) {
            assertEq(deployedWriters[i], config.writers[i]);
        }
        assertEq(aggregator.eligibilityWriter(), config.eligibilityWriter);
        assertEq(aggregator.jurisdictionWriter(), config.jurisdictionWriter);
        assertEq(aggregator.allowedRegionCount(), config.allowedRegions.length);
        assertEq(aggregator.requiredEligibilityMask(), config.requiredEligibilityMask);
        assertEq(aggregator.minLiveSources(), config.minLiveSources);
        assertEq(aggregator.maxSilence(), config.maxSilence);
        assertEq(aggregator.cycleCloseInterval(), config.cycleCloseInterval);
        assertEq(aggregator.seasoningWindow(), config.seasoningWindow);
        assertEq(aggregator.maxJumpBps(), config.maxJumpBps);
        assertEq(aggregator.maxDispersionBps(), config.maxDispersionBps);
        assertEq(aggregator.maxFirstPriceUsdc6(), config.maxFirstPriceUsdc6);
        assertEq(aggregator.valueCeilingUsdc6(), config.valueCeilingUsdc6);

        // Proof (ii), ENG-4397 §0: the deployed country digest equals keccak256(utf8
        // "fabrica.jurisdiction.country:United States") >> 193, the same digest the live
        // jurisdiction fact and the api's own jurisdiction-fact.ts encode.
        assertEq(aggregator.allowedCountryDigest(), uint128(0x20c94d9e35139ec9));
    }

    function test_runWithConfig_refusesMainnet() public {
        vm.chainId(1);
        FabricaRegionRuleAggregator.Config memory config = _liveConfig();
        vm.expectRevert(
            abi.encodeWithSelector(FabricaRegionRuleAggregatorDeployScript.MainnetIsNotInScope.selector, uint256(1))
        );
        script.runWithConfig(config);
    }

    function test_runWithConfig_refusesUnsupportedChain() public {
        vm.chainId(137);
        FabricaRegionRuleAggregator.Config memory config = _liveConfig();
        vm.expectRevert(
            abi.encodeWithSelector(FabricaRegionRuleAggregatorDeployScript.UnsupportedChain.selector, uint256(137))
        );
        script.runWithConfig(config);
    }

    function test_runWithConfig_refusesNonCanonicalFactStore() public {
        FabricaRegionRuleAggregator.Config memory config = _liveConfig();
        config.factStore = address(0xdead);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaRegionRuleAggregatorDeployScript.NonCanonicalFactStore.selector,
                address(0xdead),
                SEPOLIA_FACT_STORE
            )
        );
        script.runWithConfig(config);
    }

    function test_runWithConfig_refusesNonCanonicalUsdc() public {
        FabricaRegionRuleAggregator.Config memory config = _liveConfig();
        config.usdc = address(0xdead);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaRegionRuleAggregatorDeployScript.NonCanonicalUsdc.selector, address(0xdead), SEPOLIA_USDC
            )
        );
        script.runWithConfig(config);
    }

    function test_runWithConfig_refusesNonCanonicalEligibilityMask() public {
        FabricaRegionRuleAggregator.Config memory config = _liveConfig();
        config.requiredEligibilityMask = 0x1;
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaRegionRuleAggregatorDeployScript.NonCanonicalEligibilityMask.selector,
                uint128(0x1),
                REQUIRED_ELIGIBILITY_MASK
            )
        );
        script.runWithConfig(config);
    }
}
