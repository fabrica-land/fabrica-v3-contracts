// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

type TokenProxy is address;
type TokenImplementation is address;

contract FabricaTokenUpgradeScript is Script {
    bytes32 internal constant INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    struct UpgradeConfig {
        address tokenProxy;
        address newImplementation;
        bytes initializerData;
        uint256 requiredInitializedVersion;
    }

    function setUp() public {}

    // Sepolia-like environments still at _initialized = 5: upgrade impl + run V6 (no-op, 5 -> 6).
    function run(TokenProxy tokenProxy, TokenImplementation newImplementation) public {
        _upgradeWithInitializer(tokenProxy, newImplementation, abi.encodeCall(FabricaToken.initializeV6, ()), 5);
    }

    // Current Sepolia: already at _initialized = 6. Upgrade impl only.
    function runNoInit(TokenProxy tokenProxy, TokenImplementation newImplementation) public {
        _upgradeWithInitializer(tokenProxy, newImplementation, "", 6);
    }

    // Mainnet / Base Sepolia (ENG-3145): V4 not yet consumed. Step 1 of the V4 -> V5 -> V6
    // ceremony — upgrade impl + run V4 (owner migration). Follow with runV5Only then runV6Only.
    function runWithV4(TokenProxy tokenProxy, TokenImplementation newImplementation) public {
        _upgradeWithInitializer(tokenProxy, newImplementation, abi.encodeCall(FabricaToken.initializeV4, ()), 0);
    }

    function _upgradeWithInitializer(
        TokenProxy tokenProxy,
        TokenImplementation newImplementation,
        bytes memory initializerData,
        uint256 requiredInitializedVersion
    ) internal {
        _upgrade(
            UpgradeConfig({
                tokenProxy: TokenProxy.unwrap(tokenProxy),
                newImplementation: TokenImplementation.unwrap(newImplementation),
                initializerData: initializerData,
                requiredInitializedVersion: requiredInitializedVersion
            })
        );
    }

    function _upgrade(UpgradeConfig memory config) internal {
        _validateTargets(config.tokenProxy, config.newImplementation);
        FabricaToken proxy = FabricaToken(config.tokenProxy);
        require(
            _initializedVersion(config.tokenProxy) == config.requiredInitializedVersion,
            "unexpected initialized version"
        );
        console.log("Proxy address:", config.tokenProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Upgrading to:", config.newImplementation);
        vm.startBroadcast();
        proxy.upgradeToAndCall(config.newImplementation, config.initializerData);
        vm.stopBroadcast();
        _logState(proxy);
    }

    function _validateTargets(address tokenProxy, address newImplementation) internal view {
        require(tokenProxy != address(0), "token proxy zero");
        require(newImplementation != address(0), "new implementation zero");
        require(tokenProxy != newImplementation, "proxy and implementation match");
        require(newImplementation.code.length != 0, "new implementation has no code");
        _validateProxyTarget(tokenProxy);
        _validateTokenImplementation(newImplementation);
    }

    function _validateProxyTarget(address tokenProxy) internal view {
        require(tokenProxy.code.length != 0, "token proxy has no code");
        address currentImplementation = _proxyImplementation(tokenProxy);
        require(currentImplementation != address(0), "token proxy missing implementation");
        require(currentImplementation.code.length != 0, "current implementation has no code");
    }

    function _validateTokenImplementation(address newImplementation) internal view {
        (bool okDefaultValidator,) = newImplementation.staticcall(abi.encodeCall(FabricaToken.defaultValidator, ()));
        require(okDefaultValidator, "new implementation is not FabricaToken");
        (bool okValidatorRegistry,) = newImplementation.staticcall(abi.encodeCall(FabricaToken.validatorRegistry, ()));
        require(okValidatorRegistry, "new implementation is not FabricaToken");
    }

    // Mainnet step 2 (after runWithV4): run V5 (no-op, version bump 4 -> 5).
    function runV5Only(address tokenProxy) public {
        _runInitializer(
            tokenProxy, "Running initializeV5 (no-op, version bump)", abi.encodeCall(FabricaToken.initializeV5, ()), 4
        );
    }

    // Mainnet step 3 (after runV5Only): run V6 (ENG-3145 no-op version stamp, 5 -> 6).
    function runV6Only(address tokenProxy) public {
        _runInitializer(
            tokenProxy, "Running initializeV6 (no-op, version bump)", abi.encodeCall(FabricaToken.initializeV6, ()), 5
        );
    }

    function _runInitializer(
        address tokenProxy,
        string memory label,
        bytes memory initializerData,
        uint256 requiredInitializedVersion
    ) internal {
        _validateProxyTarget(tokenProxy);
        require(_initializedVersion(tokenProxy) == requiredInitializedVersion, "unexpected initialized version");
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
        return uint256(vm.load(tokenProxy, INITIALIZABLE_SLOT)) & type(uint64).max;
    }

    function _proxyImplementation(address tokenProxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(tokenProxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _logState(FabricaToken proxy) internal view {
        console.log("Proxy upgraded");
        console.log("Verified implementation:", proxy.implementation());
        console.log("Owner:", proxy.owner());
        console.log("Default validator:", proxy.defaultValidator());
        console.log("Validator registry:", proxy.validatorRegistry());
    }
}
