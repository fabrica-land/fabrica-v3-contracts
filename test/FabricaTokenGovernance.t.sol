// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {FabricaProxy} from "../src/FabricaProxy.sol";
import {IFabricaValidator} from "../src/IFabricaValidator.sol";

// Minimal mock validator that satisfies IFabricaValidator
contract MockValidator is IFabricaValidator {
    function defaultOperatingAgreement() external pure returns (string memory) {
        return "https://example.com/oa";
    }
    function operatingAgreementName(string memory) external pure returns (string memory) {
        return "Default OA";
    }
    function uri(uint256) external pure returns (string memory) {
        return "https://example.com/uri";
    }
}

contract FabricaTokenGovernanceTest is Test {
    FabricaToken public token;
    MockValidator public validator;
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);

    function setUp() public {
        // Deploy implementation
        FabricaToken impl = new FabricaToken();
        // Deploy proxy with initialize() call
        FabricaProxy proxy = new FabricaProxy(
            address(impl),
            address(this),
            abi.encodeCall(FabricaToken.initialize, ())
        );
        token = FabricaToken(address(proxy));
        validator = new MockValidator();
        token.setDefaultValidator(address(validator));
    }

    // Helper: mint a token with a given total supply split between alice and bob
    function _mintSplit(uint256 aliceAmount, uint256 bobAmount) internal returns (uint256) {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = aliceAmount;
        amounts[1] = bobAmount;
        uint256 sessionId = uint256(keccak256(abi.encodePacked(aliceAmount, bobAmount)));
        return token.mint(
            recipients,
            sessionId,
            amounts,
            "https://example.com/definition",
            "",
            "config",
            address(0)
        );
    }

    // Helper: mint a token 100% owned by alice
    function _mintSoleOwner() internal returns (uint256) {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        return token.mint(
            recipients,
            42,
            amounts,
            "https://example.com/definition",
            "",
            "config",
            address(0)
        );
    }

    // --- updateOperatingAgreement (70% threshold) ---

    function test_updateOA_exactlyAt70Percent() public {
        // Alice owns exactly 70 out of 100 (70%)
        uint256 id = _mintSplit(70, 30);
        vm.prank(alice);
        bool result = token.updateOperatingAgreement("https://new-oa.com", id);
        assertTrue(result, "Exactly 70% owner should be able to update OA");
    }

    function test_updateOA_above70Percent() public {
        // Alice owns 71 out of 100 (71%)
        uint256 id = _mintSplit(71, 29);
        vm.prank(alice);
        bool result = token.updateOperatingAgreement("https://new-oa.com", id);
        assertTrue(result, "71% owner should be able to update OA");
    }

    function test_updateOA_below70Percent_reverts() public {
        // Alice owns 69 out of 100 (69%)
        uint256 id = _mintSplit(69, 31);
        vm.prank(alice);
        vm.expectRevert("Only >= 70% can update");
        token.updateOperatingAgreement("https://new-oa.com", id);
    }

    function test_updateOA_100PercentOwner() public {
        uint256 id = _mintSoleOwner();
        vm.prank(alice);
        bool result = token.updateOperatingAgreement("https://new-oa.com", id);
        assertTrue(result, "100% owner should be able to update OA");
    }

    function test_updateOA_zeroBalance_reverts() public {
        uint256 id = _mintSplit(70, 30);
        vm.prank(address(0xBEEF));
        vm.expectRevert("Only >= 70% can update");
        token.updateOperatingAgreement("https://new-oa.com", id);
    }

    // --- updateConfiguration (50% threshold) ---

    function test_updateConfig_exactlyAt50Percent() public {
        // Alice owns exactly 50 out of 100 (50%)
        uint256 id = _mintSplit(50, 50);
        vm.prank(alice);
        bool result = token.updateConfiguration("new-config", id);
        assertTrue(result, "Exactly 50% owner should be able to update config");
    }

    function test_updateConfig_above50Percent() public {
        // Alice owns 51 out of 100 (51%)
        uint256 id = _mintSplit(51, 49);
        vm.prank(alice);
        bool result = token.updateConfiguration("new-config", id);
        assertTrue(result, "51% owner should be able to update config");
    }

    function test_updateConfig_below50Percent_reverts() public {
        // Alice owns 49 out of 100 (49%)
        uint256 id = _mintSplit(49, 51);
        vm.prank(alice);
        vm.expectRevert("Only >= 50% can update");
        token.updateConfiguration("new-config", id);
    }

    // --- updateValidator (70% threshold) ---

    function test_updateValidator_exactlyAt70Percent() public {
        // Alice owns exactly 70 out of 100 (70%)
        uint256 id = _mintSplit(70, 30);
        vm.prank(alice);
        bool result = token.updateValidator(address(0xDEAD), id);
        assertTrue(result, "Exactly 70% owner should be able to update validator");
    }

    function test_updateValidator_below70Percent_reverts() public {
        // Alice owns 69 out of 100 (69%)
        uint256 id = _mintSplit(69, 31);
        vm.prank(alice);
        vm.expectRevert("Only >= 70% can update");
        token.updateValidator(address(0xDEAD), id);
    }

    // --- Edge case: Math.mulDiv rounding ---

    function test_updateConfig_roundingDown_reverts() public {
        // Alice owns 1 out of 3. Math.mulDiv(1, 100, 3) = 33 (rounds down). 33 < 50.
        uint256 id = _mintSplit(1, 2);
        vm.prank(alice);
        vm.expectRevert("Only >= 50% can update");
        token.updateConfiguration("new-config", id);
    }

    function test_updateOA_roundingDown_boundary() public {
        // Alice owns 7 out of 10. Math.mulDiv(7, 100, 10) = 70. 70 >= 70.
        uint256 id = _mintSplit(7, 3);
        vm.prank(alice);
        bool result = token.updateOperatingAgreement("https://new-oa.com", id);
        assertTrue(result, "7/10 ownership (70%) should pass >= 70% threshold");
    }
}
