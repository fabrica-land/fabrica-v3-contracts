// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaValidator} from "../src/FabricaValidator.sol";

contract FabricaValidatorUpgradeScript is Script {
    function setUp() public {}

    function run(address validatorProxy, address newImplementation) public {
        FabricaValidator proxy = FabricaValidator(validatorProxy);
        console.log("Proxy address:", validatorProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Upgrading to:", newImplementation);
        vm.startBroadcast();
        proxy.upgradeToAndCall(newImplementation, abi.encodeCall(FabricaValidator.initialize, ()));
        vm.stopBroadcast();
        console.log("Proxy upgraded");
        console.log("Verified implementation:", proxy.implementation());
        console.log("Owner:", proxy.owner());
    }
}
