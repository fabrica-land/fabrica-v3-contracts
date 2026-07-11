// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FabricaSettlement} from "../src/FabricaSettlement.sol";

contract FabricaSettlementDeployScript is Script {
    function run() external returns (FabricaSettlement settlement) {
        address seaport = vm.envAddress("SEAPORT_ADDRESS");
        address morpho = vm.envAddress("MORPHO_ADDRESS");
        address owner = vm.envAddress("SETTLEMENT_OWNER");

        vm.startBroadcast();
        settlement = new FabricaSettlement(seaport, morpho, owner);
        vm.stopBroadcast();
        console.log("FabricaSettlement deployed at:", address(settlement));
    }
}
