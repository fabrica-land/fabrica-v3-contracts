// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

contract FabricaTokenUpgradeScript is Script {
    function setUp() public {}

    // Sepolia: V4 already consumed (2025-02-12). Upgrade impl + run V5 (no-op).
    function run(address tokenProxy, address newImplementation) public {
        FabricaToken proxy = FabricaToken(tokenProxy);
        console.log("Proxy address:", tokenProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Upgrading to:", newImplementation);
        vm.startBroadcast();
        proxy.upgradeToAndCall(newImplementation, abi.encodeCall(FabricaToken.initializeV5, ()));
        vm.stopBroadcast();
        _logState(proxy);
    }

    // Mainnet / Base Sepolia: V4 not yet consumed. Upgrade impl + run V4 (owner migration).
    function runWithV4(address tokenProxy, address newImplementation) public {
        FabricaToken proxy = FabricaToken(tokenProxy);
        console.log("Proxy address:", tokenProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Upgrading to:", newImplementation);
        vm.startBroadcast();
        proxy.upgradeToAndCall(newImplementation, abi.encodeCall(FabricaToken.initializeV4, ()));
        vm.stopBroadcast();
        _logState(proxy);
    }

    // Follow-up after runWithV4: run V5 (no-op, bumps version to match Sepolia).
    function runV5Only(address tokenProxy) public {
        FabricaToken proxy = FabricaToken(tokenProxy);
        console.log("Proxy address:", tokenProxy);
        console.log("Running initializeV5 (no-op, version bump)");
        vm.startBroadcast();
        proxy.initializeV5();
        vm.stopBroadcast();
        _logState(proxy);
    }

    function _logState(FabricaToken proxy) internal view {
        console.log("Proxy upgraded");
        console.log("Verified implementation:", proxy.implementation());
        console.log("Owner:", proxy.owner());
        console.log("Default validator:", proxy.defaultValidator());
        console.log("Validator registry:", proxy.validatorRegistry());
    }
}
