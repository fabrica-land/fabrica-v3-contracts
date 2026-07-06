// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

contract FabricaTokenUpgradeScript is Script {
    function setUp() public {}

    // Sepolia (ENG-3145): already at _initialized = 5. Upgrade impl + run V6 (no-op, 5 -> 6).
    function run(address tokenProxy, address newImplementation) public {
        _upgrade(tokenProxy, newImplementation, abi.encodeCall(FabricaToken.initializeV6, ()));
    }

    // Sepolia after ENG-3145: already at _initialized = 6. Upgrade impl only.
    function runNoInit(address tokenProxy, address newImplementation) public {
        _upgrade(tokenProxy, newImplementation, "");
    }

    // Mainnet / Base Sepolia (ENG-3145): V4 not yet consumed. Step 1 of the V4 -> V5 -> V6
    // ceremony — upgrade impl + run V4 (owner migration). Follow with runV5Only then runV6Only.
    function runWithV4(address tokenProxy, address newImplementation) public {
        _upgrade(tokenProxy, newImplementation, abi.encodeCall(FabricaToken.initializeV4, ()));
    }

    function _upgrade(address tokenProxy, address newImplementation, bytes memory data) internal {
        FabricaToken proxy = FabricaToken(tokenProxy);
        console.log("Proxy address:", tokenProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Upgrading to:", newImplementation);
        vm.startBroadcast();
        proxy.upgradeToAndCall(newImplementation, data);
        vm.stopBroadcast();
        _logState(proxy);
    }

    // Mainnet step 2 (after runWithV4): run V5 (no-op, version bump 4 -> 5).
    function runV5Only(address tokenProxy) public {
        FabricaToken proxy = FabricaToken(tokenProxy);
        console.log("Proxy address:", tokenProxy);
        console.log("Running initializeV5 (no-op, version bump)");
        vm.startBroadcast();
        proxy.initializeV5();
        vm.stopBroadcast();
        _logState(proxy);
    }

    // Mainnet step 3 (after runV5Only): run V6 (ENG-3145 no-op version stamp, 5 -> 6).
    function runV6Only(address tokenProxy) public {
        FabricaToken proxy = FabricaToken(tokenProxy);
        console.log("Proxy address:", tokenProxy);
        console.log("Running initializeV6 (no-op, version bump)");
        vm.startBroadcast();
        proxy.initializeV6();
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
