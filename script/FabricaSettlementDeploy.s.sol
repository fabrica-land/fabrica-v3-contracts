// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FabricaSettlement} from "../src/FabricaSettlement.sol";

contract FabricaSettlementDeployScript is Script {
    function run() external returns (FabricaSettlement settlement) {
        address seaport = vm.envAddress("SEAPORT");
        address morpho = vm.envAddress("MORPHO");
        address owner = vm.envAddress("OWNER");
        address[] memory initialPools = vm.envAddress("SETTLEMENT_INITIAL_POOLS", ",");

        require(seaport != address(0), "SEAPORT must not be zero");
        require(morpho != address(0), "MORPHO must not be zero");
        require(owner != address(0), "OWNER must not be zero");
        for (uint256 i; i < initialPools.length; ++i) {
            require(initialPools[i] != address(0), "SETTLEMENT_INITIAL_POOLS contains zero");
        }

        console2.log("Seaport:", seaport);
        console2.log("Morpho:", morpho);
        console2.log("Owner:", owner);
        console2.log("Initial pool count:", initialPools.length);
        for (uint256 i; i < initialPools.length; ++i) {
            console2.log("Initial pool:", initialPools[i]);
        }

        vm.startBroadcast();
        settlement = new FabricaSettlement(seaport, morpho, owner, initialPools);
        vm.stopBroadcast();
        console2.log("FabricaSettlement deployed at:", address(settlement));
    }
}
