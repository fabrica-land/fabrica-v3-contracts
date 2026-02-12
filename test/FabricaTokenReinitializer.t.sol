// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {FabricaProxy} from "../src/FabricaProxy.sol";

contract FabricaTokenReinitializerTest is Test {
    FabricaToken public token;
    address public proxyAdmin;
    address public attacker;

    function setUp() public {
        proxyAdmin = address(0xAD);
        attacker = address(0xBAD);
        // Deploy implementation
        FabricaToken impl = new FabricaToken();
        // Deploy proxy with initialize() call and set proxyAdmin
        bytes memory initData = abi.encodeCall(FabricaToken.initialize, ());
        FabricaProxy proxy = new FabricaProxy(address(impl), proxyAdmin, initData);
        token = FabricaToken(address(proxy));
    }

    function test_initializeV2_revertsForNonAdmin() public {
        vm.prank(attacker);
        vm.expectRevert("FabricaUUPSUpgradeable: caller is not the proxy admin");
        token.initializeV2();
    }

    function test_initializeV3_revertsForNonAdmin() public {
        vm.prank(attacker);
        vm.expectRevert("FabricaUUPSUpgradeable: caller is not the proxy admin");
        token.initializeV3();
    }

    function test_initializeV2_succeedsForProxyAdmin() public {
        vm.prank(proxyAdmin);
        token.initializeV2();
    }

    function test_initializeV3_succeedsForProxyAdmin() public {
        // Must call V2 first since reinitializers must be sequential
        vm.prank(proxyAdmin);
        token.initializeV2();
        vm.prank(proxyAdmin);
        token.initializeV3();
    }

    function test_initializeV3_viaUpgradeToAndCall() public {
        // First call V2 directly as admin
        vm.prank(proxyAdmin);
        token.initializeV2();
        // Deploy a new implementation
        FabricaToken newImpl = new FabricaToken();
        // Upgrade and call initializeV3 atomically via upgradeToAndCall
        vm.prank(proxyAdmin);
        token.upgradeToAndCall(address(newImpl), abi.encodeCall(FabricaToken.initializeV3, ()));
    }
}
