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
        TokenProxy tokenProxy;
        TokenImplementation newImplementation;
        bytes initializerData;
        uint256 requiredInitializedVersion;
        address expectedCurrentImplementation;
    }

    struct ExpectedContext {
        bool configured;
        uint256 chainId;
        address tokenProxy;
        address tokenImplementation;
        address currentImplementation;
    }

    struct ExpectedUpgradeContextInput {
        uint256 chainId;
        address tokenProxy;
        address tokenImplementation;
        address currentImplementation;
    }

    struct ExpectedInitializerContextInput {
        uint256 chainId;
        address tokenProxy;
        address currentImplementation;
    }

    ExpectedContext internal expectedContext;

    function setUp() public {}

    function configureExpectedUpgradeContext(ExpectedUpgradeContextInput memory input) public {
        expectedContext = ExpectedContext({
            configured: true,
            chainId: input.chainId,
            tokenProxy: input.tokenProxy,
            tokenImplementation: input.tokenImplementation,
            currentImplementation: input.currentImplementation
        });
    }

    function configureExpectedInitializerContext(ExpectedInitializerContextInput memory input) public {
        expectedContext = ExpectedContext({
            configured: true,
            chainId: input.chainId,
            tokenProxy: input.tokenProxy,
            tokenImplementation: address(0),
            currentImplementation: input.currentImplementation
        });
    }

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
        address expectedCurrentImplementation = _requireExpectedUpgradeContext(tokenProxy, newImplementation);
        _upgrade(
            UpgradeConfig({
                tokenProxy: tokenProxy,
                newImplementation: newImplementation,
                initializerData: initializerData,
                requiredInitializedVersion: requiredInitializedVersion,
                expectedCurrentImplementation: expectedCurrentImplementation
            })
        );
    }

    function _upgrade(UpgradeConfig memory config) internal {
        _validateTargets(config.tokenProxy, config.newImplementation, config.expectedCurrentImplementation);
        address tokenProxy = TokenProxy.unwrap(config.tokenProxy);
        address newImplementation = TokenImplementation.unwrap(config.newImplementation);
        FabricaToken proxy = FabricaToken(tokenProxy);
        require(
            _initializedVersion(config.tokenProxy) == config.requiredInitializedVersion,
            "unexpected initialized version"
        );
        console.log("Proxy address:", tokenProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Upgrading to:", newImplementation);
        vm.startBroadcast();
        proxy.upgradeToAndCall(newImplementation, config.initializerData);
        vm.stopBroadcast();
        _logState(proxy);
    }

    function _validateTargets(
        TokenProxy tokenProxy,
        TokenImplementation newImplementation,
        address expectedCurrentImplementation
    ) internal view {
        address tokenProxyAddress = TokenProxy.unwrap(tokenProxy);
        address newImplementationAddress = TokenImplementation.unwrap(newImplementation);
        require(tokenProxyAddress != address(0), "token proxy zero");
        require(newImplementationAddress != address(0), "new implementation zero");
        require(tokenProxyAddress != newImplementationAddress, "proxy and implementation match");
        require(newImplementationAddress.code.length != 0, "new implementation has no code");
        _validateProxyTarget(tokenProxy, expectedCurrentImplementation);
        _validateTokenImplementation(newImplementation);
    }

    function _validateProxyTarget(TokenProxy tokenProxy, address expectedCurrentImplementation) internal view {
        address tokenProxyAddress = TokenProxy.unwrap(tokenProxy);
        require(tokenProxyAddress.code.length != 0, "token proxy has no code");
        address currentImplementation = _proxyImplementation(tokenProxy);
        require(currentImplementation != address(0), "token proxy missing implementation");
        require(currentImplementation.code.length != 0, "current implementation has no code");
        require(currentImplementation == expectedCurrentImplementation, "unexpected current implementation");
    }

    function _validateTokenImplementation(TokenImplementation newImplementation) internal view {
        address newImplementationAddress = TokenImplementation.unwrap(newImplementation);
        (bool okDefaultValidator,) =
            newImplementationAddress.staticcall(abi.encodeCall(FabricaToken.defaultValidator, ()));
        require(okDefaultValidator, "new implementation is not FabricaToken");
        (bool okValidatorRegistry,) =
            newImplementationAddress.staticcall(abi.encodeCall(FabricaToken.validatorRegistry, ()));
        require(okValidatorRegistry, "new implementation is not FabricaToken");
    }

    function _requireExpectedUpgradeContext(TokenProxy tokenProxy, TokenImplementation newImplementation)
        internal
        view
        returns (address)
    {
        _requireExpectedChain();
        require(TokenProxy.unwrap(tokenProxy) == _expectedTokenProxy(), "unexpected token proxy");
        require(
            TokenImplementation.unwrap(newImplementation) == _expectedTokenImplementation(),
            "unexpected token implementation"
        );
        return _expectedCurrentImplementation();
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
        TokenProxy typedTokenProxy = TokenProxy.wrap(tokenProxy);
        address expectedCurrentImplementation = _requireExpectedInitializerContext(typedTokenProxy);
        _validateProxyTarget(typedTokenProxy, expectedCurrentImplementation);
        require(_initializedVersion(typedTokenProxy) == requiredInitializedVersion, "unexpected initialized version");
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

    function _requireExpectedInitializerContext(TokenProxy tokenProxy) internal view returns (address) {
        _requireExpectedChain();
        require(TokenProxy.unwrap(tokenProxy) == _expectedTokenProxy(), "unexpected token proxy");
        return _expectedCurrentImplementation();
    }

    function _requireExpectedChain() internal view {
        require(block.chainid == _expectedChainId(), "unexpected chain id");
    }

    function _expectedChainId() internal view returns (uint256) {
        return expectedContext.configured ? expectedContext.chainId : vm.envUint("EXPECTED_CHAIN_ID");
    }

    function _expectedTokenProxy() internal view returns (address) {
        return expectedContext.configured ? expectedContext.tokenProxy : vm.envAddress("EXPECTED_TOKEN_PROXY");
    }

    function _expectedTokenImplementation() internal view returns (address) {
        return expectedContext.configured
            ? expectedContext.tokenImplementation
            : vm.envAddress("EXPECTED_TOKEN_IMPLEMENTATION");
    }

    function _expectedCurrentImplementation() internal view returns (address) {
        return expectedContext.configured
            ? expectedContext.currentImplementation
            : vm.envAddress("EXPECTED_CURRENT_IMPLEMENTATION");
    }

    function _initializedVersion(TokenProxy tokenProxy) internal view returns (uint256) {
        return uint256(vm.load(TokenProxy.unwrap(tokenProxy), INITIALIZABLE_SLOT)) & type(uint64).max;
    }

    function _proxyImplementation(TokenProxy tokenProxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(TokenProxy.unwrap(tokenProxy), ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _logState(FabricaToken proxy) internal view {
        console.log("Proxy upgraded");
        console.log("Verified implementation:", proxy.implementation());
        console.log("Owner:", proxy.owner());
        console.log("Default validator:", proxy.defaultValidator());
        console.log("Validator registry:", proxy.validatorRegistry());
    }
}
