// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

contract FabricaTokenDeployImplScript is Script {
    function setUp() public {}

    function run(address tokenProxy) public {
        FabricaToken proxy = FabricaToken(tokenProxy);
        console.log("Proxy address:", tokenProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Proxy admin:", proxy.proxyAdmin());
        console.log("Owner:", proxy.owner());
        vm.startBroadcast();
        FabricaToken newImplementation = new FabricaToken();
        vm.stopBroadcast();
        console.log("New implementation deployed at:", address(newImplementation));
    }
}
