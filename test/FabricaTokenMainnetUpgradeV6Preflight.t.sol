// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

/// @notice ENG-3007 FINAL pre-flight (read-only fork; never broadcasts/signs). Verifies the EXACT
/// mainnet FabricaToken V4 -> V5 -> V6 Safe multi-call before the calldata is locked, against
/// canele's burn-remint-guard impl (origin/eng-3145-burn-remint-guard @ 536c93b — the source of the
/// deployed V6 impl 0xF8b3...730b; `new FabricaToken()` here is byte-equivalent). Live mainnet token
/// is OZ v4 with _initialized == 3 (V4, V5, V6 all unrun).
///
/// The real Safe MultiSend = three actions, pranked as the proxyAdmin Safe:
///   1) upgradeToAndCall(newImpl, initializeV4())   (owner migration)
///   2) initializeV5()                              (no-op; __legacy_gap is structural)
///   3) initializeV6()                              (no-op version stamp; burn-remint build marker)
contract FabricaTokenMainnetUpgradeV6PreflightTest is Test {
    address constant TOKEN = 0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95;
    address constant SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0; // proxyAdmin == owner (verified)
    uint256 constant MAINNET_BLOCK = 25_237_790;

    uint256 constant SLOT_DEFAULT_VALIDATOR = 304;
    uint256 constant SLOT_VALIDATOR_REGISTRY = 305;
    uint256 constant SLOT_CONTRACT_URI = 306;
    bytes32 constant INITIALIZABLE_V5_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    uint256 constant ID0 = 10_239_548_241_764_155_858;
    address constant ID0_HOLDER = 0x8c8a949c0B83233bDf56a2C82d5336b1B43628b0;
    uint256 constant ID1 = 14_544_113_128_183_520_803;
    uint256 constant ID2 = 3_775_392_155_688_387_140;

    FabricaToken token = FabricaToken(TOKEN);

    function _skip() internal view returns (bool) {
        return bytes(vm.envOr("MAINNET_RPC_URL", string(""))).length == 0;
    }

    struct Prop {
        uint256 supply;
        string oa;
        string def;
        string cfg;
        address validator;
    }

    function _prop(uint256 id) internal view returns (Prop memory p) {
        (p.supply, p.oa, p.def, p.cfg, p.validator) = token._property(id);
    }

    function _eq(Prop memory a, Prop memory b) internal pure returns (bool) {
        return a.supply == b.supply && keccak256(bytes(a.oa)) == keccak256(bytes(b.oa))
            && keccak256(bytes(a.def)) == keccak256(bytes(b.def)) && keccak256(bytes(a.cfg)) == keccak256(bytes(b.cfg))
            && a.validator == b.validator;
    }

    function _v4Initialized() internal view returns (uint256) {
        return uint256(vm.load(TOKEN, bytes32(uint256(0)))) & 0xff; // v4: slot 0 low byte
    }

    function _v5Initialized() internal view returns (uint256) {
        return uint256(vm.load(TOKEN, INITIALIZABLE_V5_SLOT)) & 0xff; // v5: namespaced slot
    }

    function _safeCall(bytes memory data, string memory why) internal {
        vm.prank(SAFE);
        (bool ok,) = TOKEN.call(data);
        assertTrue(ok, why);
    }

    function _upgradeV4V5V6(address impl) internal {
        _safeCall(
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", impl, abi.encodeWithSignature("initializeV4()")),
            "action 1: upgradeToAndCall(initializeV4()) must succeed"
        );
        _safeCall(abi.encodeWithSignature("initializeV5()"), "action 2: initializeV5() must succeed");
        _safeCall(abi.encodeWithSignature("initializeV6()"), "action 3: initializeV6() must succeed");
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _one(uint256 v) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = v;
    }

    // ----------------------------------------------------------------------------------------------
    // 1) CORE: V4+V5+V6 preserves owner + all data; symbol == FABRICA; _initialized == 6; and the
    //    burn-remint guard works on the real impl (the part untestable on ad9401e8).
    // ----------------------------------------------------------------------------------------------
    function test_mainnet_V4V5V6_preservesEverything_andGuardWorks() public {
        if (_skip()) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);
        assertLt(_v4Initialized(), 4, "precondition: V4 unrun (_initialized < 4)");
        console2.log("_initialized before:", _v4Initialized());

        // ---- BEFORE snapshot ----
        address ownerBefore = token.owner();
        bool pausedBefore = token.paused();
        bytes32 s304 = vm.load(TOKEN, bytes32(SLOT_DEFAULT_VALIDATOR));
        bytes32 s305 = vm.load(TOKEN, bytes32(SLOT_VALIDATOR_REGISTRY));
        bytes32 s306 = vm.load(TOKEN, bytes32(SLOT_CONTRACT_URI));
        address dv = token.defaultValidator();
        address vr = token.validatorRegistry();
        string memory cu = token.contractURI();
        Prop memory p0 = _prop(ID0);
        Prop memory p1 = _prop(ID1);
        Prop memory p2 = _prop(ID2);
        uint256 bal = token.balanceOf(ID0_HOLDER, ID0);
        assertGt(p0.supply, 0, "precondition: ID0 live");
        assertGt(bal, 0, "precondition: holder holds ID0");
        console2.log("owner before:", ownerBefore);

        // ---- APPLY V4 -> V5 -> V6 ----
        _upgradeV4V5V6(address(new FabricaToken()));

        // ---- owner preserved + version 6 ----
        assertEq(token.owner(), ownerBefore, "owner() preserved through V4 migration");
        assertTrue(token.owner() != address(0), "owner() must not be address(0)");
        assertEq(_v5Initialized(), 6, "_initialized must be 6 (V6 ran)");

        // ---- all data preserved ----
        assertEq(vm.load(TOKEN, bytes32(SLOT_DEFAULT_VALIDATOR)), s304, "slot 304 preserved");
        assertEq(vm.load(TOKEN, bytes32(SLOT_VALIDATOR_REGISTRY)), s305, "slot 305 preserved");
        assertEq(vm.load(TOKEN, bytes32(SLOT_CONTRACT_URI)), s306, "slot 306 preserved");
        assertEq(token.defaultValidator(), dv, "defaultValidator() preserved");
        assertEq(token.validatorRegistry(), vr, "validatorRegistry() preserved");
        assertEq(keccak256(bytes(token.contractURI())), keccak256(bytes(cu)), "contractURI() preserved");
        assertTrue(_eq(p0, _prop(ID0)), "ID0 _property preserved");
        assertTrue(_eq(p1, _prop(ID1)), "ID1 _property preserved");
        assertTrue(_eq(p2, _prop(ID2)), "ID2 _property preserved");
        assertEq(token.balanceOf(ID0_HOLDER, ID0), bal, "balanceOf preserved");
        assertEq(token.paused(), pausedBefore, "paused() preserved");
        assertEq(token.symbol(), "FABRICA", "symbol() == FABRICA");
        console2.log("owner after:", token.owner());
        console2.log("_initialized after:", _v5Initialized());

        // ---- BURN-REMINT GUARD (the V6 build's purpose) ----
        address minter = makeAddr("v6-minter");
        if (minter.code.length > 0) vm.etch(minter, "");
        uint256 sid = 555_111;
        string memory oa = "ipfs://v6-test-oa";
        vm.prank(minter);
        uint256 id = token.mint(_one(minter), sid, _one(uint256(5)), "def", oa, "{}", address(0));
        assertEq(token.balanceOf(minter, id), 5, "fresh mint succeeds post-upgrade");
        vm.prank(minter);
        token.burn(minter, id, 5);
        (uint256 sup,, string memory def,,) = token._property(id);
        assertEq(sup, 0, "burned to zero");
        assertGt(bytes(def).length, 0, "definition retained as the permanent never-minted marker");
        // Re-minting the SAME (minter, sessionId, oa) -> same id -> guard reverts on the definition marker.
        vm.prank(minter);
        vm.expectRevert("Session ID already exist, please use a different one");
        token.mint(_one(minter), sid, _one(uint256(1)), "def2", oa, "{}", address(0));
        console2.log("burn-remint guard: re-mint of burned id reverted (guard active)");
    }

    // ----------------------------------------------------------------------------------------------
    // 2) NEGATIVE CONTROL: V5-only (Sepolia-style, skipping V4) bricks owner() -> V4 is mandatory.
    // ----------------------------------------------------------------------------------------------
    function test_mainnet_negativeControl_V5only_breaksOwner() public {
        if (_skip()) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);
        address ownerBefore = token.owner();
        assertTrue(ownerBefore != address(0), "precondition: owner set");
        _safeCall(
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)",
                address(new FabricaToken()),
                abi.encodeWithSignature("initializeV5()")
            ),
            "V5-only upgrade call itself succeeds (the danger)"
        );
        console2.log("owner before:        ", ownerBefore);
        console2.log("owner after V5-only: ", token.owner());
        assertEq(token.owner(), address(0), "NEGATIVE CONTROL: V5-only leaves owner() == address(0) -> V4 MANDATORY");
    }

    // ----------------------------------------------------------------------------------------------
    // 3) VERSION CONTROL: V4+V5 lands at 5; V6 is what bumps 5 -> 6; and the V6 ceremony is one-shot.
    // ----------------------------------------------------------------------------------------------
    function test_mainnet_version_landsAt6_andV6IsOneShot() public {
        if (_skip()) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);
        address impl = address(new FabricaToken());
        _safeCall(
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", impl, abi.encodeWithSignature("initializeV4()")),
            "V4"
        );
        _safeCall(abi.encodeWithSignature("initializeV5()"), "V5");
        uint256 afterV5 = _v5Initialized();
        _safeCall(abi.encodeWithSignature("initializeV6()"), "V6");
        uint256 afterV6 = _v5Initialized();
        console2.log("version after V4+V5:", afterV5);
        console2.log("version after +V6: ", afterV6);
        assertEq(afterV5, 5, "after V4+V5, _initialized == 5");
        assertEq(afterV6, 6, "V6 bumps _initialized 5 -> 6 (V6 actually runs)");

        // Re-running V6 must revert (one-shot ceremony — reinitializer(6) with _initialized already 6).
        vm.prank(SAFE);
        (bool reran,) = TOKEN.call(abi.encodeWithSignature("initializeV6()"));
        assertFalse(reran, "re-running initializeV6() must revert (InvalidInitialization)");
    }
}
