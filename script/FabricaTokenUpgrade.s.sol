// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

contract FabricaTokenUpgradeScript is Script {
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    struct UpgradeConfig {
        address tokenProxy;
        address newImplementation;
        bytes initializerData;
        uint256 requiredInitializedVersion;
    }

    function setUp() public {}

    // Sepolia-like environments still at _initialized = 5: upgrade impl + run V6 (no-op, 5 -> 6).
    function run(address tokenProxy, address newImplementation) public {
        _upgrade(
            UpgradeConfig({
                tokenProxy: tokenProxy,
                newImplementation: newImplementation,
                initializerData: abi.encodeCall(FabricaToken.initializeV6, ()),
                requiredInitializedVersion: 0
            })
        );
    }

    // Current Sepolia: already at _initialized = 6. Upgrade impl only.
    function runNoInit(address tokenProxy, address newImplementation) public {
        _upgrade(
            UpgradeConfig({
                tokenProxy: tokenProxy,
                newImplementation: newImplementation,
                initializerData: "",
                requiredInitializedVersion: 6
            })
        );
    }

    // Mainnet / Base Sepolia (ENG-3145): V4 not yet consumed. Step 1 of the V4 -> V5 -> V6
    // ceremony — upgrade impl + run V4 (owner migration). Follow with runV5Only then runV6Only.
    function runWithV4(address tokenProxy, address newImplementation) public {
        _upgrade(
            UpgradeConfig({
                tokenProxy: tokenProxy,
                newImplementation: newImplementation,
                initializerData: abi.encodeCall(FabricaToken.initializeV4, ()),
                requiredInitializedVersion: 0
            })
        );
    }

    function _upgrade(UpgradeConfig memory config) internal {
        FabricaToken proxy = FabricaToken(config.tokenProxy);
        if (config.requiredInitializedVersion != 0) {
            require(
                _initializedVersion(config.tokenProxy) == config.requiredInitializedVersion,
                "unexpected initialized version"
            );
        }
        console.log("Proxy address:", config.tokenProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Upgrading to:", config.newImplementation);
        vm.startBroadcast();
        proxy.upgradeToAndCall(config.newImplementation, config.initializerData);
        vm.stopBroadcast();
        _logState(proxy);
    }

    // Mainnet step 2 (after runWithV4): run V5 (no-op, version bump 4 -> 5).
    function runV5Only(address tokenProxy) public {
        _runInitializer(
            tokenProxy, "Running initializeV5 (no-op, version bump)", abi.encodeCall(FabricaToken.initializeV5, ())
        );
    }

    // Mainnet step 3 (after runV5Only): run V6 (ENG-3145 no-op version stamp, 5 -> 6).
    function runV6Only(address tokenProxy) public {
        _runInitializer(
            tokenProxy, "Running initializeV6 (no-op, version bump)", abi.encodeCall(FabricaToken.initializeV6, ())
        );
    }

    function _runInitializer(address tokenProxy, string memory label, bytes memory initializerData) internal {
        FabricaToken proxy = FabricaToken(tokenProxy);
        console.log("Proxy address:", tokenProxy);
        console.log(label);
        vm.startBroadcast();
        (bool ok, bytes memory revertData) = tokenProxy.call(initializerData);
        if (!ok) {
            assembly {
                revert(add(revertData, 32), mload(revertData))
            }
        }
        vm.stopBroadcast();
        _logState(proxy);
    }

    function _initializedVersion(address tokenProxy) internal view returns (uint256) {
        return uint256(vm.load(tokenProxy, INITIALIZABLE_SLOT)) & 0xff;
    }

    function _logState(FabricaToken proxy) internal view {
        console.log("Proxy upgraded");
        console.log("Verified implementation:", proxy.implementation());
        console.log("Owner:", proxy.owner());
        console.log("Default validator:", proxy.defaultValidator());
        console.log("Validator registry:", proxy.validatorRegistry());
    }
}
