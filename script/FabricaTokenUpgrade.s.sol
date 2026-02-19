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
        // initializeV5 migrates the owner from OZ v4 linear storage (slot 101)
        // to OZ v5 ERC-7201 namespaced storage and validates the __legacy_gap
        // storage fix. Supersedes initializeV4 (never deployed). Must be called
        // once per network during the v4→v5 upgrade.
        proxy.upgradeToAndCall(newImplementation, abi.encodeCall(FabricaToken.initializeV5, ()));
        vm.stopBroadcast();
        console.log("Proxy upgraded");
        console.log("Verified implementation:", proxy.implementation());
        console.log("Owner:", proxy.owner());
        console.log("Default validator:", proxy.defaultValidator());
        console.log("Validator registry:", proxy.validatorRegistry());
    }
}
