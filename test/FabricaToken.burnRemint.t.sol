// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {IFabricaValidator} from "../src/IFabricaValidator.sol";
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

/// @dev Re-enters `mint` (single) during `onERC1155Received`. Because this contract is the
/// minter, `generateId` keys on `address(this)`, so a re-entrant mint with the same
/// sessionId + operatingAgreement targets the SAME id as the outer mint — the case the
/// uniqueness guard must defend against. The outer mint writes `_property[id]` (which sets the
/// `definition` marker the guard keys on) BEFORE the acceptance-check callback (the CEI reorder),
/// so the re-entrant same-id mint sees a non-empty definition and reverts.
contract ReentrantMintReceiver is IERC1155Receiver {
    FabricaToken public token;
    address public validator;
    uint256 public sessionId;
    string public oa;
    bool public attempted;
    bool public reentryReverted;
    string public revertReason;

    function configure(FabricaToken _token, address _validator, uint256 _sessionId, string memory _oa) external {
        token = _token;
        validator = _validator;
        sessionId = _sessionId;
        oa = _oa;
    }

    function startAttack(string memory definition) external returns (uint256) {
        address[] memory recipients = new address[](1);
        recipients[0] = address(this);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        return token.mint(recipients, sessionId, amounts, definition, oa, "{}", validator);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4) {
        if (!attempted) {
            attempted = true;
            // Re-enter with the same sessionId + operatingAgreement → same id as the outer mint.
            address[] memory recipients = new address[](1);
            recipients[0] = address(this);
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 100;
            try token.mint(recipients, sessionId, amounts, "ipfs://def-REENTRANT", oa, "{}", validator) {
            // Reaching here means the uniqueness guard was bypassed (the pre-fix bug).
            }
            catch Error(string memory reason) {
                reentryReverted = true;
                revertReason = reason;
            }
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

/// @dev Same as ReentrantMintReceiver but for the batch path: re-enters `mintBatch` during
/// `onERC1155BatchReceived` with the same sessionId + operatingAgreement → same id.
contract ReentrantMintBatchReceiver is IERC1155Receiver {
    FabricaToken public token;
    address public validator;
    uint256 public sessionId;
    string public oa;
    bool public attempted;
    bool public reentryReverted;
    string public revertReason;

    function configure(FabricaToken _token, address _validator, uint256 _sessionId, string memory _oa) external {
        token = _token;
        validator = _validator;
        sessionId = _sessionId;
        oa = _oa;
    }

    function startAttack(string memory definition) external returns (uint256) {
        return _doMintBatch(definition)[0];
    }

    function _doMintBatch(string memory definition) internal returns (uint256[] memory) {
        address[] memory recipients = new address[](1);
        recipients[0] = address(this);
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = sessionId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        string[] memory defs = new string[](1);
        defs[0] = definition;
        string[] memory oas = new string[](1);
        oas[0] = oa;
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        address[] memory validators = new address[](1);
        validators[0] = validator;
        return token.mintBatch(recipients, sessionIds, amounts, defs, oas, configs, validators);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        returns (bytes4)
    {
        if (!attempted) {
            attempted = true;
            address[] memory recipients = new address[](1);
            recipients[0] = address(this);
            uint256[] memory sessionIds = new uint256[](1);
            sessionIds[0] = sessionId;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 100;
            string[] memory defs = new string[](1);
            defs[0] = "ipfs://def-REENTRANT";
            string[] memory oas = new string[](1);
            oas[0] = oa;
            string[] memory configs = new string[](1);
            configs[0] = "{}";
            address[] memory validators = new address[](1);
            validators[0] = validator;
            try token.mintBatch(recipients, sessionIds, amounts, defs, oas, configs, validators) {
            // Reaching here means the uniqueness guard was bypassed (the pre-fix bug).
            }
            catch Error(string memory reason) {
                reentryReverted = true;
                revertReason = reason;
            }
        }
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}

/// @notice ENG-3145: burning a token to zero supply must not let the original minter re-mint the
/// same id and overwrite its property data, on EITHER the `mint` or `mintBatch` path (they derive
/// the same id from generateId and write the same `_property` slot). The guard keys on the
/// permanent `_property[id].definition` marker — required non-empty on every mint, never cleared
/// by `_burn`, no setter — so it also retires ids minted/burned BEFORE this upgrade with no
/// migration. Also covers N-1: the `_mint` CEI reorder (property written before the receiver
/// callbacks).
contract FabricaTokenBurnRemintTest is Test {
    FabricaToken public token;
    MockValidator public validator;
    address public operator = makeAddr("operator");

    string constant REVERT_MSG = "Session ID already exist, please use a different one";
    // Storage slot of the `_property` mapping (see FabricaToken's storage-layout comment).
    uint256 constant SLOT_PROPERTY = 303;

    function setUp() public {
        FabricaToken impl = new FabricaToken();
        bytes memory initData = abi.encodeCall(FabricaToken.initialize, ());
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = FabricaToken(address(proxy));
        validator = new MockValidator();
        token.setDefaultValidator(address(validator));
    }

    function _mint(uint256 sessionId, uint256 amount, string memory def, string memory oa) internal returns (uint256) {
        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        return token.mint(recipients, sessionId, amounts, def, oa, "{}", address(validator));
    }

    function _mintBatchSingle(uint256 sessionId, uint256 amount, string memory def, string memory oa)
        internal
        returns (uint256)
    {
        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = sessionId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        string[] memory defs = new string[](1);
        defs[0] = def;
        string[] memory oas = new string[](1);
        oas[0] = oa;
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        address[] memory validators = new address[](1);
        validators[0] = address(validator);
        return token.mintBatch(recipients, sessionIds, amounts, defs, oas, configs, validators)[0];
    }

    /// @dev Write `_property[id].definition` directly to storage (struct offset +2 within the
    /// `_property` mapping slot) while leaving supply at 0, to model a token that was minted and
    /// fully burned BEFORE this upgrade — i.e. one that never ran through the new mint path and
    /// has no flag, only the legacy definition that `_burn` left behind. Short, non-empty strings
    /// only (Solidity inline layout: data left-aligned, 2*length in the low byte).
    function _seedLegacyDefinition(uint256 id, string memory def) internal {
        uint256 len = bytes(def).length;
        require(len > 0 && len < 32, "test helper: short non-empty string only");
        bytes32 word;
        assembly {
            word := mload(add(def, 32))
        }
        bytes32 mask = bytes32(~uint256(0) << (8 * (32 - len)));
        bytes32 packed = (word & mask) | bytes32(len * 2);
        bytes32 base = keccak256(abi.encode(id, SLOT_PROPERTY));
        vm.store(address(token), bytes32(uint256(base) + 2), packed);
    }

    function _assertProperty(
        uint256 id,
        uint256 expSupply,
        string memory expOA,
        string memory expDef,
        address expValidator
    ) internal view {
        (uint256 supply, string memory oa, string memory def,, address val) = token._property(id);
        assertEq(supply, expSupply, "supply");
        assertEq(oa, expOA, "operatingAgreement");
        assertEq(def, expDef, "definition");
        assertEq(val, expValidator, "validator");
    }

    /// @dev Core ENG-3145 repro on the single-mint path: mint -> burn to zero -> remint same
    /// sessionId+OA must REVERT, and the original property data must be left untouched.
    function test_mint_burnToZero_remintSameId_reverts() public {
        uint256 id = token.generateId(operator, 1, "ipfs://oa-1");

        vm.startPrank(operator);
        uint256 mintedId = _mint(1, 100, "ParcelA", "ipfs://oa-1");
        assertEq(mintedId, id, "minted id should match generateId");
        _assertProperty(id, 100, "ipfs://oa-1", "ParcelA", address(validator));

        // Burn the full supply. `_burn` zeroes supply but never clears `definition`, so the id
        // can never be re-minted.
        token.burn(operator, id, 100);
        _assertProperty(id, 0, "ipfs://oa-1", "ParcelA", address(validator));

        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        vm.expectRevert(bytes(REVERT_MSG));
        token.mint(recipients, 1, amounts, "ParcelB", "ipfs://oa-1", "{}", address(validator));
        vm.stopPrank();

        // Property unchanged: definition was NOT overwritten by the burn-remint attempt.
        _assertProperty(id, 0, "ipfs://oa-1", "ParcelA", address(validator));
    }

    /// @dev Same repro on the batch path — `_mintBatch` must carry the identical guard.
    function test_mintBatch_burnToZero_remintSameId_reverts() public {
        uint256 id = token.generateId(operator, 1, "ipfs://oa-1");

        vm.startPrank(operator);
        uint256 mintedId = _mintBatchSingle(1, 100, "ParcelA", "ipfs://oa-1");
        assertEq(mintedId, id, "minted id should match generateId");
        _assertProperty(id, 100, "ipfs://oa-1", "ParcelA", address(validator));

        token.burn(operator, id, 100);
        _assertProperty(id, 0, "ipfs://oa-1", "ParcelA", address(validator));

        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        string[] memory defs = new string[](1);
        defs[0] = "ParcelB";
        string[] memory oas = new string[](1);
        oas[0] = "ipfs://oa-1";
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        address[] memory validators = new address[](1);
        validators[0] = address(validator);
        vm.expectRevert(bytes(REVERT_MSG));
        token.mintBatch(recipients, sessionIds, amounts, defs, oas, configs, validators);
        vm.stopPrank();

        _assertProperty(id, 0, "ipfs://oa-1", "ParcelA", address(validator));
    }

    /// @dev Cross-path: an id first minted via `mint`, burned to zero, cannot be re-minted via
    /// `mintBatch` (same generateId → same `_property` slot → same `definition` marker).
    function test_crossPath_mintThenBurnThenMintBatch_reverts() public {
        vm.startPrank(operator);
        uint256 id = _mint(2, 100, "ParcelA", "ipfs://oa-2");
        token.burn(operator, id, 100);

        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = 2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        string[] memory defs = new string[](1);
        defs[0] = "ParcelB";
        string[] memory oas = new string[](1);
        oas[0] = "ipfs://oa-2";
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        address[] memory validators = new address[](1);
        validators[0] = address(validator);
        vm.expectRevert(bytes(REVERT_MSG));
        token.mintBatch(recipients, sessionIds, amounts, defs, oas, configs, validators);
        vm.stopPrank();

        _assertProperty(id, 0, "ipfs://oa-2", "ParcelA", address(validator));
    }

    /// @dev Cross-path the other direction: minted via `mintBatch`, burned, cannot re-mint via `mint`.
    function test_crossPath_mintBatchThenBurnThenMint_reverts() public {
        vm.startPrank(operator);
        uint256 id = _mintBatchSingle(3, 100, "ParcelA", "ipfs://oa-3");
        token.burn(operator, id, 100);

        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        vm.expectRevert(bytes(REVERT_MSG));
        token.mint(recipients, 3, amounts, "ParcelB", "ipfs://oa-3", "{}", address(validator));
        vm.stopPrank();

        _assertProperty(id, 0, "ipfs://oa-3", "ParcelA", address(validator));
    }

    /// @dev The guard is independent of the validator field: minting with validator==address(0)
    /// (so the stored validator is the resolved default) still blocks burn-then-remint. This is
    /// the case the validator-sentinel approach could not handle — `definition` does.
    function test_mint_defaultValidator_burnRemint_reverts() public {
        vm.startPrank(operator);
        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        uint256 id = token.mint(recipients, 5, amounts, "ParcelA", "ipfs://oa-5", "{}", address(0));
        // Passing address(0) resolves to the default validator; the guard does not depend on it.
        _assertProperty(id, 100, "ipfs://oa-5", "ParcelA", address(validator));

        token.burn(operator, id, 100);

        amounts[0] = 50;
        vm.expectRevert(bytes(REVERT_MSG));
        token.mint(recipients, 5, amounts, "ParcelB", "ipfs://oa-5", "{}", address(0));
        vm.stopPrank();

        _assertProperty(id, 0, "ipfs://oa-5", "ParcelA", address(validator));
    }

    /// @dev The guard must still block re-minting an id whose supply is still > 0 (the original
    /// active-id duplicate-session protection).
    function test_mint_duplicateActiveSessionId_reverts() public {
        vm.startPrank(operator);
        _mint(1, 100, "ParcelA", "ipfs://oa-1");
        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.expectRevert(bytes(REVERT_MSG));
        token.mint(recipients, 1, amounts, "ParcelB", "ipfs://oa-1", "{}", address(validator));
        vm.stopPrank();
    }

    /// @dev The guard must not over-block: after a full burn, a FRESH id (different session)
    /// still mints normally.
    function test_mint_burnToZero_freshSession_succeeds() public {
        vm.startPrank(operator);
        uint256 id1 = _mint(1, 100, "ParcelA", "ipfs://oa-1");
        token.burn(operator, id1, 100);
        uint256 id2 = _mint(2, 100, "ParcelB", "ipfs://oa-1");
        vm.stopPrank();

        assertTrue(id1 != id2, "different sessionId must yield a different id");
        _assertProperty(id2, 100, "ipfs://oa-1", "ParcelB", address(validator));
        assertEq(token.balanceOf(operator, id2), 100);
    }

    /// @dev N-1: a re-entrant `mint` during `onERC1155Received` cannot bypass the guard or corrupt
    /// `_property`. The property (and its `definition` marker) is written BEFORE the callback, so
    /// the re-entrant same-id mint reverts; the outer mint completes with its own data and an
    /// un-inflated balance.
    function test_mint_reentrancy_cannotBypassGuardOrCorruptProperty() public {
        ReentrantMintReceiver attacker = new ReentrantMintReceiver();
        attacker.configure(token, address(validator), 1, "ipfs://oa-1");

        uint256 expectedId = token.generateId(address(attacker), 1, "ipfs://oa-1");
        uint256 id = attacker.startAttack("ipfs://def-OUTER");
        assertEq(id, expectedId, "outer mint id");

        assertTrue(attacker.attempted(), "reentrancy path should have executed");
        assertTrue(attacker.reentryReverted(), "re-entrant mint must revert on the guard");
        assertEq(attacker.revertReason(), REVERT_MSG);

        _assertProperty(id, 100, "ipfs://oa-1", "ipfs://def-OUTER", address(validator));
        assertEq(token.balanceOf(address(attacker), id), 100, "balance must not be inflated by reentrancy");
    }

    /// @dev Same reentrancy guarantee on the batch path via `onERC1155BatchReceived`.
    function test_mintBatch_reentrancy_cannotBypassGuardOrCorruptProperty() public {
        ReentrantMintBatchReceiver attacker = new ReentrantMintBatchReceiver();
        attacker.configure(token, address(validator), 1, "ipfs://oa-1");

        uint256 expectedId = token.generateId(address(attacker), 1, "ipfs://oa-1");
        uint256 id = attacker.startAttack("ipfs://def-OUTER");
        assertEq(id, expectedId, "outer mint id");

        assertTrue(attacker.attempted(), "reentrancy path should have executed");
        assertTrue(attacker.reentryReverted(), "re-entrant mintBatch must revert on the guard");
        assertEq(attacker.revertReason(), REVERT_MSG);

        _assertProperty(id, 100, "ipfs://oa-1", "ipfs://def-OUTER", address(validator));
        assertEq(token.balanceOf(address(attacker), id), 100, "balance must not be inflated by reentrancy");
    }

    /// @dev THE GAP THIS PR CLOSES (single path): an id minted and fully burned BEFORE this
    /// upgrade has supply == 0 but a non-empty stored `definition` (`_burn` never clears it). The
    /// earlier `_everMinted`-flag approach left such ids re-mintable (their flag was never set);
    /// the definition-based guard blocks them with no migration. Seed only the legacy definition
    /// directly into storage (no mint, no flag), then assert a same-id mint reverts without
    /// overwriting the stored definition.
    function test_mint_legacyBurnedToken_cannotBeReminted() public {
        uint256 id = token.generateId(operator, 8, "ipfs://oa-8");
        _seedLegacyDefinition(id, "LegacyParcel");
        // Precondition: a fully-burned legacy token — supply 0, definition present, no flag.
        (uint256 supply,, string memory def,,) = token._property(id);
        assertEq(supply, 0, "precondition: burned (supply 0)");
        assertEq(def, "LegacyParcel", "precondition: legacy definition present in storage");

        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        vm.prank(operator);
        vm.expectRevert(bytes(REVERT_MSG));
        token.mint(recipients, 8, amounts, "NewParcel", "ipfs://oa-8", "{}", address(validator));

        (,, string memory defAfter,,) = token._property(id);
        assertEq(defAfter, "LegacyParcel", "legacy definition must be untouched");
    }

    /// @dev Same legacy-burned-token coverage on the batch path.
    function test_mintBatch_legacyBurnedToken_cannotBeReminted() public {
        uint256 id = token.generateId(operator, 8, "ipfs://oa-8");
        _seedLegacyDefinition(id, "LegacyParcel");

        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory sessionIds = new uint256[](1);
        sessionIds[0] = 8;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        string[] memory defs = new string[](1);
        defs[0] = "NewParcel";
        string[] memory oas = new string[](1);
        oas[0] = "ipfs://oa-8";
        string[] memory configs = new string[](1);
        configs[0] = "{}";
        address[] memory validators = new address[](1);
        validators[0] = address(validator);
        vm.prank(operator);
        vm.expectRevert(bytes(REVERT_MSG));
        token.mintBatch(recipients, sessionIds, amounts, defs, oas, configs, validators);

        (,, string memory defAfter,,) = token._property(id);
        assertEq(defAfter, "LegacyParcel", "legacy definition must be untouched");
    }

    /// @dev A live pre-upgrade token (supply > 0, definition set) is likewise non-re-mintable —
    /// the definition marker blocks it regardless of supply. Seed a legacy definition AND a
    /// non-zero supply, then assert a same-id re-mint reverts and the property is untouched.
    function test_mint_legacyLiveToken_cannotBeReminted() public {
        uint256 id = token.generateId(operator, 8, "ipfs://oa-8");
        _seedLegacyDefinition(id, "LegacyParcel");
        // Give it a live supply at struct offset +0 to model a still-live pre-upgrade token.
        bytes32 base = keccak256(abi.encode(id, SLOT_PROPERTY));
        vm.store(address(token), base, bytes32(uint256(100)));
        (uint256 supply,, string memory def,,) = token._property(id);
        assertEq(supply, 100, "precondition: live supply");
        assertEq(def, "LegacyParcel", "precondition: legacy definition present");

        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        vm.prank(operator);
        vm.expectRevert(bytes(REVERT_MSG));
        token.mint(recipients, 8, amounts, "NewParcel", "ipfs://oa-8", "{}", address(validator));

        _assertProperty(id, 100, "", "LegacyParcel", address(0));
    }

    /// @dev A partial burn leaves supply > 0; the id must still be non-re-mintable.
    function test_mint_partialBurn_remintReverts() public {
        vm.startPrank(operator);
        uint256 id = _mint(9, 100, "ParcelA", "ipfs://oa-9");
        token.burn(operator, id, 40); // supply 100 -> 60
        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 50;
        vm.expectRevert(bytes(REVERT_MSG));
        token.mint(recipients, 9, amounts, "ParcelB", "ipfs://oa-9", "{}", address(validator));
        vm.stopPrank();
        _assertProperty(id, 60, "ipfs://oa-9", "ParcelA", address(validator));
    }

    /// @dev A mintBatch where one id collides with an already-minted id reverts atomically —
    /// the fresh id in the same batch is NOT created.
    function test_mintBatch_collisionInBatch_revertsAtomically() public {
        vm.startPrank(operator);
        _mint(1, 100, "ParcelA", "ipfs://oa-1");
        // Batch: [session 1 -> collides, session 2 -> fresh]; one recipient.
        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        uint256[] memory sessionIds = new uint256[](2);
        sessionIds[0] = 1;
        sessionIds[1] = 2;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10;
        string[] memory defs = new string[](2);
        defs[0] = "ParcelX";
        defs[1] = "ParcelY";
        string[] memory oas = new string[](2);
        oas[0] = "ipfs://oa-1";
        oas[1] = "ipfs://oa-2";
        string[] memory configs = new string[](2);
        configs[0] = "{}";
        configs[1] = "{}";
        address[] memory validators = new address[](2);
        validators[0] = address(validator);
        validators[1] = address(validator);
        vm.expectRevert(bytes(REVERT_MSG));
        token.mintBatch(recipients, sessionIds, amounts, defs, oas, configs, validators);
        vm.stopPrank();
        // The fresh session-2 id was never created (whole batch reverted atomically).
        uint256 freshId = token.generateId(operator, 2, "ipfs://oa-2");
        (uint256 supply,,,,) = token._property(freshId);
        assertEq(supply, 0, "fresh batch id must not exist after atomic revert");
        assertEq(token.balanceOf(operator, freshId), 0, "fresh batch id balance must be 0");
    }
}
