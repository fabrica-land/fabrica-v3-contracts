// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {IFabricaValidator} from "../src/IFabricaValidator.sol";
import {IERC1155} from "../lib/openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IERC1155Receiver} from "../lib/openzeppelin-contracts/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockValidator is IFabricaValidator {
    function defaultOperatingAgreement() external pure returns (string memory) {
        return "ipfs://default-oa";
    }

    function operatingAgreementName(string memory) external pure returns (string memory) {
        return "Test OA";
    }

    function uri(uint256) external pure returns (string memory) {
        return "ipfs://test-uri";
    }
}

contract ERC1155ReceiverMock is IERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}

contract ReentrantReceiver is IERC1155Receiver {
    FabricaToken public token;
    MockValidator public validator;
    bool public attacked;

    function setTarget(FabricaToken _token, MockValidator _validator) external {
        token = _token;
        validator = _validator;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (!attacked) {
            attacked = true;
            // Attempt reentrancy: try to mint with same sessionId
            address[] memory recipients = new address[](1);
            recipients[0] = address(this);
            uint256[] memory sessionIds = new uint256[](1);
            sessionIds[0] = 1;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 100;
            string[] memory defs = new string[](1);
            defs[0] = "ipfs://def-1";
            string[] memory oas = new string[](1);
            oas[0] = "ipfs://oa-1";
            string[] memory configs = new string[](1);
            configs[0] = "{}";
            address[] memory validators = new address[](1);
            validators[0] = address(validator);
            token.mintBatch(recipients, sessionIds, amounts, defs, oas, configs, validators);
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}

contract FabricaTokenMintBatchTest is Test {
    FabricaToken public token;
    MockValidator public validator;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        FabricaToken impl = new FabricaToken();
        bytes memory initData = abi.encodeCall(FabricaToken.initialize, ());
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = FabricaToken(address(proxy));
        validator = new MockValidator();
        token.setDefaultValidator(address(validator));
    }

    function _mintBatchSingle(address recipient, uint256 sessionId, uint256 amount)
        internal
        returns (uint256[] memory)
    {
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = sessionId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        string[] memory definitions = new string[](1);
        definitions[0] = "ipfs://def-1";
        string[] memory oas = new string[](1);
        oas[0] = "ipfs://oa-1";
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        address[] memory validators = new address[](1);
        validators[0] = address(validator);
        return token.mintBatch(recipients, sessionIds, amounts, definitions, oas, configs, validators);
    }

    function _mintBatchTwo(
        address[] memory recipients,
        uint256[] memory amounts,
        uint256 sessionId1,
        uint256 sessionId2
    ) internal returns (uint256[] memory) {
        uint256[] memory sessionIds = new uint256[](2);
        sessionIds[0] = sessionId1;
        sessionIds[1] = sessionId2;
        string[] memory definitions = new string[](2);
        definitions[0] = "ipfs://def-1";
        definitions[1] = "ipfs://def-2";
        string[] memory oas = new string[](2);
        oas[0] = "ipfs://oa-1";
        oas[1] = "ipfs://oa-2";
        string[] memory configs = new string[](2);
        configs[0] = "{}";
        configs[1] = "{}";
        address[] memory validators = new address[](2);
        validators[0] = address(validator);
        validators[1] = address(validator);
        return token.mintBatch(recipients, sessionIds, amounts, definitions, oas, configs, validators);
    }

    function test_mintBatch_singleToken_correctSupply() public {
        uint256[] memory ids = _mintBatchSingle(alice, 1, 1000);
        assertEq(ids.length, 1);
        (uint256 supply,,,,) = token._property(ids[0]);
        assertEq(supply, 1000);
        assertEq(token.balanceOf(alice, ids[0]), 1000);
    }

    function test_mintBatch_twoTokens_correctSupplyPerToken() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300;
        amounts[1] = 700;
        uint256[] memory ids = _mintBatchTwo(recipients, amounts, 1, 2);
        assertEq(ids.length, 2);
        // Each token should have supply = 300 + 700 = 1000
        (uint256 supply0,,,,) = token._property(ids[0]);
        (uint256 supply1,,,,) = token._property(ids[1]);
        assertEq(supply0, 1000);
        assertEq(supply1, 1000);
        // Each recipient gets their amount for each token
        assertEq(token.balanceOf(alice, ids[0]), 300);
        assertEq(token.balanceOf(bob, ids[0]), 700);
        assertEq(token.balanceOf(alice, ids[1]), 300);
        assertEq(token.balanceOf(bob, ids[1]), 700);
    }

    function test_mintBatch_emitsCorrectTransferSingleEvents() public {
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100;
        amounts[1] = 200;
        // Pre-compute the expected token IDs
        uint256 expectedId0 = token.generateId(address(this), 10, "ipfs://oa-1");
        uint256 expectedId1 = token.generateId(address(this), 20, "ipfs://oa-2");
        // Expect TransferSingle for token 0, alice
        vm.expectEmit(true, true, true, true);
        emit IERC1155.TransferSingle(address(this), address(0), alice, expectedId0, 100);
        // Expect TransferSingle for token 0, bob
        vm.expectEmit(true, true, true, true);
        emit IERC1155.TransferSingle(address(this), address(0), bob, expectedId0, 200);
        // Expect TransferSingle for token 1, alice
        vm.expectEmit(true, true, true, true);
        emit IERC1155.TransferSingle(address(this), address(0), alice, expectedId1, 100);
        // Expect TransferSingle for token 1, bob
        vm.expectEmit(true, true, true, true);
        emit IERC1155.TransferSingle(address(this), address(0), bob, expectedId1, 200);
        _mintBatchTwo(recipients, amounts, 10, 20);
    }

    function test_mintBatch_returnsCorrectIds() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500;
        uint256 expectedId0 = token.generateId(address(this), 10, "ipfs://oa-1");
        uint256 expectedId1 = token.generateId(address(this), 20, "ipfs://oa-2");
        uint256[] memory ids = _mintBatchTwo(recipients, amounts, 10, 20);
        assertEq(ids[0], expectedId0);
        assertEq(ids[1], expectedId1);
    }

    function test_mintBatch_contractRecipient_acceptanceCheck() public {
        ERC1155ReceiverMock receiver = new ERC1155ReceiverMock();
        address[] memory recipients = new address[](1);
        recipients[0] = address(receiver);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        uint256[] memory ids = _mintBatchTwo(recipients, amounts, 1, 2);
        assertEq(token.balanceOf(address(receiver), ids[0]), 100);
        assertEq(token.balanceOf(address(receiver), ids[1]), 100);
    }

    function test_mintBatch_revertsOnDuplicateSessionId() public {
        // First mint succeeds
        _mintBatchSingle(alice, 1, 100);
        // Second mint with same session should revert
        vm.expectRevert("Session ID already exist, please use a different one");
        _mintBatchSingle(alice, 1, 100);
    }

    function test_mintBatch_revertsOnZeroAddress() public {
        address[] memory recipients = new address[](1);
        recipients[0] = address(0);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = 1;
        string[] memory definitions = new string[](1);
        definitions[0] = "ipfs://def";
        string[] memory oas = new string[](1);
        oas[0] = "ipfs://oa";
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        address[] memory validators = new address[](1);
        validators[0] = address(validator);
        vm.expectRevert("ERC1155: mint to the zero address");
        token.mintBatch(recipients, sessionIds, amounts, definitions, oas, configs, validators);
    }

    function test_mintBatch_revertsOnZeroAmount() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        string[] memory definitions = new string[](1);
        definitions[0] = "ipfs://def";
        string[] memory oas = new string[](1);
        oas[0] = "ipfs://oa";
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        address[] memory validators = new address[](1);
        validators[0] = address(validator);
        vm.expectRevert("Each amount must be greater than zero");
        token.mintBatch(recipients, sessionIds, amounts, definitions, oas, configs, validators);
    }

    function test_mintBatch_defaultValidator() public {
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        string[] memory definitions = new string[](1);
        definitions[0] = "ipfs://def";
        string[] memory oas = new string[](1);
        oas[0] = "ipfs://oa";
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        // Pass zero address as validator to trigger default
        address[] memory validators = new address[](1);
        validators[0] = address(0);
        uint256[] memory ids = token.mintBatch(recipients, sessionIds, amounts, definitions, oas, configs, validators);
        (,,,, address storedValidator) = token._property(ids[0]);
        assertEq(storedValidator, address(validator));
    }

    function test_mintBatch_reentrancyCannotDuplicateId() public {
        // Reentrancy creates a DIFFERENT token because generateId uses
        // _msgSender() — the re-entrant caller has a different address.
        // Property stored before external calls provides defense-in-depth.
        ReentrantReceiver attacker = new ReentrantReceiver();
        attacker.setTarget(token, validator);
        address[] memory recipients = new address[](1);
        recipients[0] = address(attacker);
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        string[] memory definitions = new string[](1);
        definitions[0] = "ipfs://def-1";
        string[] memory oas = new string[](1);
        oas[0] = "ipfs://oa-1";
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        address[] memory validators = new address[](1);
        validators[0] = address(validator);
        uint256[] memory ids = token.mintBatch(recipients, sessionIds, amounts, definitions, oas, configs, validators);
        // Outer mint succeeded with correct supply
        assertEq(ids.length, 1);
        (uint256 supply,,,,) = token._property(ids[0]);
        assertEq(supply, 100);
        assertEq(token.balanceOf(address(attacker), ids[0]), 100);
        // Verify the re-entrant call created a different token (different ID)
        uint256 attackerTokenId = token.generateId(address(attacker), 1, "ipfs://oa-1");
        assertTrue(ids[0] != attackerTokenId);
        assertTrue(attacker.attacked());
    }
}
