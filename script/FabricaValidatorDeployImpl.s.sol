// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaValidator} from "../src/FabricaValidator.sol";

contract FabricaValidatorDeployImplScript is Script {
    function setUp() public {}

    function run(address validatorProxy) public {
        FabricaValidator proxy = FabricaValidator(validatorProxy);
        console.log("Proxy address:", validatorProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Proxy admin:", proxy.proxyAdmin());
        console.log("Owner:", proxy.owner());
        vm.startBroadcast();
        FabricaValidator newImplementation = new FabricaValidator();
        vm.stopBroadcast();
        console.log("New implementation deployed at:", address(newImplementation));
    }
}
