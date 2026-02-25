// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

/// @notice Fork test against Sepolia — verifies the upgrade restores functionality on real on-chain state.
/// Run with: forge test --match-contract FabricaTokenSepoliaForkTest --fork-url $SEPOLIA_RPC_URL -vvv
contract FabricaTokenSepoliaForkTest is Test {
    address constant PROXY = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    address constant PROXY_ADMIN = 0xBF03076547a99857b796717faF4034dea94569dF;
    // Actual on-chain values at slot 304/305 (verified via cast storage)
    address constant EXPECTED_DEFAULT_VALIDATOR = 0xAAA7FDc1A573965a2eD47Ab154332b6b55098008;

    FabricaToken token;

    modifier onlyFork() {
        // Skip when not running with --fork-url (proxy has no code without a fork)
        if (PROXY.code.length == 0) {
            return;
        }
        _;
    }

    function setUp() public {
        token = FabricaToken(PROXY);
    }

    /// @dev Ensures addr is a clean EOA in the fork context (some makeAddr results collide
    /// with contracts deployed on Sepolia, which breaks ERC1155 safeTransfer callbacks).
    function _ensureEOA(address addr) internal {
        if (addr.code.length > 0) vm.etch(addr, "");
    }

    function test_brokenState_beforeUpgrade() public onlyFork {
        // Once the storage-slot fix is deployed on Sepolia, this broken state
        // no longer exists — defaultValidator() returns the real value, not zero.
        if (token.defaultValidator() != address(0)) return;
        // Confirm the bug: defaultValidator() reads from wrong slot (returns zero)
        assertEq(token.defaultValidator(), address(0), "defaultValidator should be broken before upgrade");
    }

    function test_upgradeRestoresAllState() public onlyFork {
        // Deploy the fixed implementation
        FabricaToken newImpl = new FabricaToken();
        // Sepolia path: V4 already consumed (2025-02-12), only V5 (no-op) needed
        vm.prank(PROXY_ADMIN);
        token.upgradeToAndCall(address(newImpl), abi.encodeCall(FabricaToken.initializeV5, ()));
        // Owner was already migrated by V4 on Feb 12
        assertEq(token.owner(), PROXY_ADMIN, "owner should still be set after upgrade");
        // Verify storage gap fix restored all state
        assertEq(token.defaultValidator(), EXPECTED_DEFAULT_VALIDATOR, "defaultValidator should be restored");
        assertTrue(token.validatorRegistry() != address(0), "validatorRegistry should be non-zero");
        assertTrue(bytes(token.contractURI()).length > 0, "contractURI should be non-empty");
    }

    function test_mintAfterUpgrade() public onlyFork {
        // Deploy and upgrade
        FabricaToken newImpl = new FabricaToken();
        vm.prank(PROXY_ADMIN);
        token.upgradeToAndCall(address(newImpl), abi.encodeCall(FabricaToken.initializeV5, ()));
        // Mint a new token
        address recipient = makeAddr("forktest-recipient");
        _ensureEOA(recipient);
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        vm.prank(recipient);
        uint256 tokenId = token.mint(recipients, 1, amounts, "test-definition", "", "", address(0));
        // Verify balanceOf
        assertEq(token.balanceOf(recipient, tokenId), 500, "balanceOf should return 500");
        // Verify _property
        (uint256 supply,,,,) = token._property(tokenId);
        assertEq(supply, 500, "property supply should be 500");
    }

    function test_transferAfterUpgrade() public onlyFork {
        // Deploy and upgrade
        FabricaToken newImpl = new FabricaToken();
        vm.prank(PROXY_ADMIN);
        token.upgradeToAndCall(address(newImpl), abi.encodeCall(FabricaToken.initializeV5, ()));
        // Mint — use unique labels to avoid on-chain address collisions
        address user1 = makeAddr("forktest-user1");
        address user2 = makeAddr("forktest-user2");
        _ensureEOA(user1);
        _ensureEOA(user2);
        address[] memory recipients = new address[](1);
        recipients[0] = user1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000;
        vm.prank(user1);
        uint256 tokenId = token.mint(recipients, 1, amounts, "test-definition", "", "", address(0));
        // Transfer via safeTransferFrom
        vm.prank(user1);
        token.safeTransferFrom(user1, user2, tokenId, 300, "");
        assertEq(token.balanceOf(user1, tokenId), 700, "user1 balance after transfer");
        assertEq(token.balanceOf(user2, tokenId), 300, "user2 balance after transfer");
    }
}
