// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {FabricaProxy} from "../src/FabricaProxy.sol";

contract FabricaTokenOwnerMigrationTest is Test {
    FabricaToken public token;
    address public proxy;
    address public proxyAdmin;
    address public expectedOwner;

    // OZ v4 linear storage slot for OwnableUpgradeable._owner
    uint256 constant OZ_V4_OWNER_SLOT = 101;

    // OZ v5 ERC-7201 namespaced slot for OwnableUpgradeable._owner
    bytes32 constant OZ_V5_OWNER_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    function setUp() public {
        proxyAdmin = makeAddr("proxyAdmin");
        expectedOwner = makeAddr("expectedOwner");
        FabricaToken impl = new FabricaToken();
        bytes memory initData = abi.encodeCall(FabricaToken.initialize, ());
        FabricaProxy proxyContract = new FabricaProxy(address(impl), proxyAdmin, initData);
        proxy = address(proxyContract);
        token = FabricaToken(proxy);
    }

    function test_initializeV4_migratesOwnerFromSlot101() public {
        // Simulate OZ v4→v5 state: owner in slot 101 but zeroed in ERC-7201 slot
        vm.store(proxy, bytes32(uint256(OZ_V4_OWNER_SLOT)), bytes32(uint256(uint160(expectedOwner))));
        vm.store(proxy, OZ_V5_OWNER_SLOT, bytes32(0));
        // Verify pre-migration state
        assertEq(token.owner(), address(0), "Owner should be zero before migration");
        assertEq(
            address(uint160(uint256(vm.load(proxy, bytes32(uint256(OZ_V4_OWNER_SLOT)))))),
            expectedOwner,
            "Expected owner in OZ v4 slot 101"
        );
        // Run the migration as proxy admin
        vm.prank(proxyAdmin);
        token.initializeV4();
        // Verify post-migration state
        assertEq(token.owner(), expectedOwner, "Owner should be migrated to OZ v5 slot");
    }

    function test_initializeV4_viaUpgradeToAndCall() public {
        // Simulate OZ v4→v5 state
        vm.store(proxy, bytes32(uint256(OZ_V4_OWNER_SLOT)), bytes32(uint256(uint160(expectedOwner))));
        vm.store(proxy, OZ_V5_OWNER_SLOT, bytes32(0));
        // Deploy new implementation
        FabricaToken newImpl = new FabricaToken();
        // Upgrade and call initializeV4 atomically
        vm.prank(proxyAdmin);
        token.upgradeToAndCall(address(newImpl), abi.encodeCall(FabricaToken.initializeV4, ()));
        // Verify
        assertEq(token.owner(), expectedOwner, "Owner should be migrated after upgradeToAndCall");
        assertEq(token.implementation(), address(newImpl), "Implementation should be updated");
    }

    function test_initializeV4_revertsForNonAdmin() public {
        vm.store(proxy, bytes32(uint256(OZ_V4_OWNER_SLOT)), bytes32(uint256(uint160(expectedOwner))));
        vm.store(proxy, OZ_V5_OWNER_SLOT, bytes32(0));
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert("FabricaUUPSUpgradeable: caller is not the proxy admin");
        token.initializeV4();
    }

    function test_initializeV4_revertsIfNoLegacyOwner() public {
        vm.store(proxy, bytes32(uint256(OZ_V4_OWNER_SLOT)), bytes32(0));
        vm.store(proxy, OZ_V5_OWNER_SLOT, bytes32(0));
        vm.prank(proxyAdmin);
        vm.expectRevert("No owner found in legacy storage slot");
        token.initializeV4();
    }

    function test_initializeV4_cannotBeCalledTwice() public {
        vm.store(proxy, bytes32(uint256(OZ_V4_OWNER_SLOT)), bytes32(uint256(uint160(expectedOwner))));
        vm.store(proxy, OZ_V5_OWNER_SLOT, bytes32(0));
        vm.prank(proxyAdmin);
        token.initializeV4();
        assertEq(token.owner(), expectedOwner);
        // Calling again should revert (reinitializer already consumed)
        vm.prank(proxyAdmin);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        token.initializeV4();
    }
}
