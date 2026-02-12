// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

contract FabricaTokenUpgradeScript is Script {
    function setUp() public {}

    function run(address tokenProxy, address newImplementation) public {
        FabricaToken proxy = FabricaToken(tokenProxy);
        console.log("Proxy address:", tokenProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Upgrading to:", newImplementation);
        vm.startBroadcast();
        // initializeV3 is the latest reinitializer — it can be called whether
        // the proxy is at version 1 or 2, since reinitializer(3) only requires
        // the current version to be < 3.
        proxy.upgradeToAndCall(newImplementation, abi.encodeCall(FabricaToken.initializeV3, ()));
        vm.stopBroadcast();
        console.log("Proxy upgraded");
        console.log("Verified implementation:", proxy.implementation());
        console.log("Owner:", proxy.owner());
    }
}
