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
        // initializeV4 migrates the owner from OZ v4 linear storage (slot 101)
        // to OZ v5 ERC-7201 namespaced storage. Must be called once per network
        // during the v4→v5 upgrade.
        proxy.upgradeToAndCall(newImplementation, abi.encodeCall(FabricaToken.initializeV4, ()));
        vm.stopBroadcast();
        console.log("Proxy upgraded");
        console.log("Verified implementation:", proxy.implementation());
        console.log("Owner:", proxy.owner());
    }
}
