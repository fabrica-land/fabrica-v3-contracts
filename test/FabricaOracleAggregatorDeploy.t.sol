// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaOracleAggregatorDeployScript} from "../script/FabricaOracleAggregatorDeploy.s.sol";

contract FabricaOracleAggregatorDeployHarness is FabricaOracleAggregatorDeployScript {
    function exposedSourceIds() external view returns (uint8[] memory) {
        return _sourceIds();
    }
}

contract FabricaOracleAggregatorDeployScriptTest is Test {
    FabricaOracleAggregatorDeployHarness internal script;

    function setUp() public {
        script = new FabricaOracleAggregatorDeployHarness();
    }

    function test_sourceIdsRejectDuplicateEnvConfig() public {
        vm.setEnv("FABRICA_AGGREGATOR_SOURCE_IDS", "0,0");
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregatorDeployScript.DuplicateSourceId.selector, 0));
        script.exposedSourceIds();
    }
}
