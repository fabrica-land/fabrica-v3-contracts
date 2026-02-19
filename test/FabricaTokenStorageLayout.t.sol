// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {FabricaProxy} from "../src/FabricaProxy.sol";
import {FabricaValidator} from "../src/FabricaValidator.sol";
import {FabricaValidatorRegistry} from "../src/FabricaValidatorRegistry.sol";

/// @notice Verifies the FabricaToken storage layout matches the original OZ v4 slot positions.
/// The __legacy_gap[301] must keep all state variables at their historical proxy storage slots.
contract FabricaTokenStorageLayoutTest is Test {
    FabricaToken public token;
    address public proxy;
    address public proxyAdmin;
    address public owner;
    FabricaValidator public validator;
    FabricaValidatorRegistry public registry;
    // Expected slot positions (from OZ v4 era, verified on-chain)
    uint256 constant SLOT_BALANCES = 301;
    uint256 constant SLOT_OPERATOR_APPROVALS = 302;
    uint256 constant SLOT_PROPERTY = 303;
    uint256 constant SLOT_DEFAULT_VALIDATOR = 304;
    uint256 constant SLOT_VALIDATOR_REGISTRY = 305;
    uint256 constant SLOT_CONTRACT_URI = 306;

    function setUp() public {
        proxyAdmin = makeAddr("proxyAdmin");
        owner = makeAddr("owner");
        // Deploy validator and registry for mint operations
        FabricaValidator validatorImpl = new FabricaValidator();
        FabricaProxy validatorProxy = new FabricaProxy(
            address(validatorImpl),
            proxyAdmin,
            abi.encodeCall(FabricaValidator.initialize, ())
        );
        validator = FabricaValidator(address(validatorProxy));
        FabricaValidatorRegistry registryImpl = new FabricaValidatorRegistry();
        FabricaProxy registryProxy = new FabricaProxy(
            address(registryImpl),
            proxyAdmin,
            abi.encodeCall(FabricaValidatorRegistry.initialize, ())
        );
        registry = FabricaValidatorRegistry(address(registryProxy));
        // Deploy FabricaToken
        FabricaToken impl = new FabricaToken();
        FabricaProxy proxyContract = new FabricaProxy(address(impl), proxyAdmin, abi.encodeCall(FabricaToken.initialize, ()));
        proxy = address(proxyContract);
        token = FabricaToken(proxy);
        // Set owner and configure
        vm.startPrank(token.owner());
        token.setDefaultValidator(address(validator));
        token.setValidatorRegistry(address(registry));
        token.setContractURI("https://example.com/contract-uri");
        vm.stopPrank();
    }

    function test_defaultValidator_atSlot304() public view {
        bytes32 stored = vm.load(proxy, bytes32(SLOT_DEFAULT_VALIDATOR));
        assertEq(
            address(uint160(uint256(stored))),
            address(validator),
            "_defaultValidator not at expected slot 304"
        );
    }

    function test_validatorRegistry_atSlot305() public view {
        bytes32 stored = vm.load(proxy, bytes32(SLOT_VALIDATOR_REGISTRY));
        assertEq(
            address(uint160(uint256(stored))),
            address(registry),
            "_validatorRegistry not at expected slot 305"
        );
    }

    function test_contractURI_atSlot306() public view {
        // Verify via public function that the stored value matches
        assertEq(token.contractURI(), "https://example.com/contract-uri", "contractURI should match");
        // Verify the raw storage slot is non-zero at the expected position
        bytes32 stored = vm.load(proxy, bytes32(SLOT_CONTRACT_URI));
        uint256 raw = uint256(stored);
        // For strings > 31 bytes, Solidity stores (length * 2 + 1) at the base slot.
        // "https://example.com/contract-uri" is 32 bytes → long string encoding.
        // Length = 32, so stored value = 32 * 2 + 1 = 65 = 0x41.
        assertEq(raw, 65, "_contractURI slot 306 should store long-string length encoding");
    }

    function test_balances_atSlot301() public {
        // Mint a token and check the balance is at the correct slot
        address recipient = makeAddr("recipient");
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000;
        vm.prank(recipient);
        uint256 tokenId = token.mint(
            recipients, 1, amounts, "test-definition", "", "", address(0)
        );
        // Verify via public function
        assertEq(token.balanceOf(recipient, tokenId), 1000, "balanceOf should return 1000");
        // Verify storage slot: _balances is at slot 301
        // For mapping(uint256 => mapping(address => uint256)):
        // slot = keccak256(account . keccak256(tokenId . 301))
        bytes32 innerSlot = keccak256(abi.encode(tokenId, SLOT_BALANCES));
        bytes32 balanceSlot = keccak256(abi.encode(recipient, innerSlot));
        uint256 rawBalance = uint256(vm.load(proxy, balanceSlot));
        assertEq(rawBalance, 1000, "_balances not at expected slot 301");
    }

    function test_operatorApprovals_atSlot302() public {
        address approver = makeAddr("approver");
        address operator = makeAddr("operator");
        vm.prank(approver);
        token.setApprovalForAll(operator, true);
        // Verify via public function
        assertTrue(token.isApprovedForAll(approver, operator), "isApprovedForAll should be true");
        // Verify storage slot: _operatorApprovals is at slot 302
        // For mapping(address => mapping(address => bool)):
        // slot = keccak256(operator . keccak256(approver . 302))
        bytes32 innerSlot = keccak256(abi.encode(approver, SLOT_OPERATOR_APPROVALS));
        bytes32 approvalSlot = keccak256(abi.encode(operator, innerSlot));
        uint256 rawApproval = uint256(vm.load(proxy, approvalSlot));
        assertEq(rawApproval, 1, "_operatorApprovals not at expected slot 302");
    }

    function test_property_atSlot303() public {
        // Mint a token to create a property entry
        address recipient = makeAddr("recipient");
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(recipient);
        uint256 tokenId = token.mint(
            recipients, 2, amounts, "test-definition", "", "", address(0)
        );
        // Property struct: first field is `supply` (uint256)
        // For mapping(uint256 => Property), the struct base slot is:
        // keccak256(tokenId . 303)
        bytes32 propertyBaseSlot = keccak256(abi.encode(tokenId, SLOT_PROPERTY));
        uint256 rawSupply = uint256(vm.load(proxy, propertyBaseSlot));
        assertEq(rawSupply, 100, "_property.supply not at expected slot 303");
    }

    function test_initializeV5_migratesOwner() public {
        // Set up a fresh proxy simulating the upgrade scenario
        FabricaToken impl = new FabricaToken();
        FabricaProxy freshProxy = new FabricaProxy(address(impl), proxyAdmin, abi.encodeCall(FabricaToken.initialize, ()));
        address freshProxyAddr = address(freshProxy);
        FabricaToken freshToken = FabricaToken(freshProxyAddr);
        address expectedOwner = makeAddr("expectedOwner");
        // Simulate OZ v4→v5 state: owner in slot 101, zeroed in ERC-7201 slot
        bytes32 ozV5OwnerSlot = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
        vm.store(freshProxyAddr, bytes32(uint256(101)), bytes32(uint256(uint160(expectedOwner))));
        vm.store(freshProxyAddr, ozV5OwnerSlot, bytes32(0));
        assertEq(freshToken.owner(), address(0), "Owner should be zero before V5 migration");
        // Run initializeV5
        vm.prank(proxyAdmin);
        freshToken.initializeV5();
        assertEq(freshToken.owner(), expectedOwner, "Owner should be migrated by initializeV5");
    }

    function test_initializeV5_revertsForNonAdmin() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert("FabricaUUPSUpgradeable: caller is not the proxy admin");
        token.initializeV5();
    }

    function test_initializeV5_cannotBeCalledTwice() public {
        // Set up a fresh proxy
        FabricaToken impl = new FabricaToken();
        FabricaProxy freshProxy = new FabricaProxy(address(impl), proxyAdmin, abi.encodeCall(FabricaToken.initialize, ()));
        FabricaToken freshToken = FabricaToken(address(freshProxy));
        // Store an owner in slot 101
        vm.store(address(freshProxy), bytes32(uint256(101)), bytes32(uint256(uint160(makeAddr("owner2")))));
        bytes32 ozV5OwnerSlot = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
        vm.store(address(freshProxy), ozV5OwnerSlot, bytes32(0));
        // First call should succeed
        vm.prank(proxyAdmin);
        freshToken.initializeV5();
        // Second call should revert
        vm.prank(proxyAdmin);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        freshToken.initializeV5();
    }

    function test_initializeV5_viaUpgradeToAndCall() public {
        // Set up a fresh proxy
        FabricaToken impl = new FabricaToken();
        FabricaProxy freshProxy = new FabricaProxy(address(impl), proxyAdmin, abi.encodeCall(FabricaToken.initialize, ()));
        FabricaToken freshToken = FabricaToken(address(freshProxy));
        address expectedOwner = makeAddr("expectedOwner");
        // Simulate OZ v4→v5 state
        vm.store(address(freshProxy), bytes32(uint256(101)), bytes32(uint256(uint160(expectedOwner))));
        bytes32 ozV5OwnerSlot = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
        vm.store(address(freshProxy), ozV5OwnerSlot, bytes32(0));
        // Deploy new implementation and upgrade
        FabricaToken newImpl = new FabricaToken();
        vm.prank(proxyAdmin);
        freshToken.upgradeToAndCall(address(newImpl), abi.encodeCall(FabricaToken.initializeV5, ()));
        assertEq(freshToken.owner(), expectedOwner, "Owner should be migrated after upgradeToAndCall");
        assertEq(freshToken.implementation(), address(newImpl), "Implementation should be updated");
    }

    function test_allSlots_endToEnd() public {
        // This test verifies that after the gap fix, all 6 state variables
        // are functional and reading from the correct storage positions.
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address operator = makeAddr("operator");
        // 1. Mint tokens (tests _balances at 301, _property at 303, _defaultValidator at 304)
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 700;
        amounts[1] = 300;
        vm.prank(user1);
        uint256 tokenId = token.mint(
            recipients, 3, amounts, "test-definition", "", "", address(0)
        );
        assertEq(token.balanceOf(user1, tokenId), 700, "user1 balance should be 700");
        assertEq(token.balanceOf(user2, tokenId), 300, "user2 balance should be 300");
        // 2. Set approval (tests _operatorApprovals at 302)
        vm.prank(user1);
        token.setApprovalForAll(operator, true);
        assertTrue(token.isApprovedForAll(user1, operator), "operator should be approved");
        // 3. Transfer tokens (tests _balances reads AND writes)
        vm.prank(operator);
        token.safeTransferFrom(user1, user2, tokenId, 100, "");
        assertEq(token.balanceOf(user1, tokenId), 600, "user1 balance after transfer");
        assertEq(token.balanceOf(user2, tokenId), 400, "user2 balance after transfer");
        // 4. Verify _defaultValidator (slot 304)
        assertEq(token.defaultValidator(), address(validator), "defaultValidator should be set");
        // 5. Verify _validatorRegistry (slot 305)
        assertEq(token.validatorRegistry(), address(registry), "validatorRegistry should be set");
        // 6. Verify _contractURI (slot 306)
        assertEq(token.contractURI(), "https://example.com/contract-uri", "contractURI should be set");
        // 7. Verify _property (slot 303) — check supply via public getter
        (uint256 supply,,,,) = token._property(tokenId);
        assertEq(supply, 1000, "property supply should be 1000");
    }
}
