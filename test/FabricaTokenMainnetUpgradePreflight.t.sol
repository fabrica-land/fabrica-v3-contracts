// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

/// @notice ENG-3007 PRE-FLIGHT (read-only; never broadcasts/signs). Fork-verifies the EXACT mainnet
/// FabricaToken OZ v4->v5 upgrade Safe multi-call BEFORE the calldata is locked:
///   action 1: upgradeToAndCall(newImpl, abi.encodeWithSignature("initializeV4()"))  (owner migration)
///   action 2: initializeV5()                                                        (version bump; gap is structural)
/// Both run as the proxyAdmin Safe (== owner). New impl = `new FabricaToken()` compiled from
/// origin/main HEAD ad9401e8 — byte-equivalent to canele's mainnet deploy (FabricaToken.sol is
/// unchanged by PR #14). Live mainnet token is OZ v4 with _initialized == 3 (V4 and V5 both unrun).
///
/// Run: forge test --match-contract FabricaTokenMainnetUpgradePreflightTest -vv
contract FabricaTokenMainnetUpgradePreflightTest is Test {
    address constant TOKEN = 0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95;
    // proxyAdmin AND owner of the token proxy — resolved on-chain (ERC1967 admin slot + proxyAdmin()
    // + v4 slot 101 + owner()). Same Safe as the validator.
    address constant SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0;
    uint256 constant MAINNET_BLOCK = 25_237_790;

    // FabricaToken v4-layout custom-storage slots, restored by __legacy_gap[301] in the v5 impl.
    uint256 constant SLOT_DEFAULT_VALIDATOR = 304;
    uint256 constant SLOT_VALIDATOR_REGISTRY = 305;
    uint256 constant SLOT_CONTRACT_URI = 306;
    // OZ v5 ERC-7201 namespaced Initializable storage root (_initialized lives here post-upgrade).
    bytes32 constant INITIALIZABLE_V5_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    // Real live mainnet token ids (supply == 1, all routing to the default validator) + a confirmed
    // current holder of ID0.
    uint256 constant ID0 = 10_239_548_241_764_155_858;
    address constant ID0_HOLDER = 0x8c8a949c0B83233bDf56a2C82d5336b1B43628b0;
    uint256 constant ID1 = 14_544_113_128_183_520_803;
    uint256 constant ID2 = 3_775_392_155_688_387_140;

    // ENG-3256 validator fix (already deployed + verified on mainnet) — used only to demonstrate the
    // uri() dependency in test 3.
    address constant VALIDATOR = 0x170511f95560A1F280c29026f73a9cD6a4bA8ab0;
    address constant VALIDATOR_IMPL = 0x1150CfB3957152942d26f2d8cdbadb79e80D7543;
    string constant VALIDATOR_BASEURI =
        "https://metadata.fabrica.land/ethereum/0x5cbeb7a0df7ed85d82a472fd56d81ed550f3ea95/";

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

    function _propPreserved(Prop memory a, Prop memory b) internal pure returns (bool) {
        return a.supply == b.supply && keccak256(bytes(a.oa)) == keccak256(bytes(b.oa))
            && keccak256(bytes(a.def)) == keccak256(bytes(b.def)) && keccak256(bytes(a.cfg)) == keccak256(bytes(b.cfg))
            && a.validator == b.validator;
    }

    /// The EXACT Safe multi-call (two actions), pranked as the Safe.
    function _upgradeV4thenV5(address newImpl) internal {
        vm.startPrank(SAFE);
        (bool ok1,) = TOKEN.call(
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)", newImpl, abi.encodeWithSignature("initializeV4()")
            )
        );
        assertTrue(ok1, "action 1: upgradeToAndCall(initializeV4()) must succeed");
        (bool ok2,) = TOKEN.call(abi.encodeWithSignature("initializeV5()"));
        assertTrue(ok2, "action 2: initializeV5() must succeed");
        vm.stopPrank();
    }

    function _initializedLowByte(bytes32 slot) internal view returns (uint256) {
        return uint256(vm.load(TOKEN, slot)) & 0xff;
    }

    // ----------------------------------------------------------------------------------------------
    // 1) CORE: V4+V5 multi-call preserves owner + all data; applies the intended new state.
    // ----------------------------------------------------------------------------------------------
    function test_mainnet_tokenUpgrade_V4thenV5_preservesEverything() public {
        if (_skip()) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);

        uint256 initBefore = _initializedLowByte(bytes32(uint256(0))); // v4: _initialized at slot 0
        console2.log("live _initialized (before):", initBefore);
        assertLt(initBefore, 4, "precondition: V4 not yet run (_initialized < 4)");

        // ---- BEFORE snapshot (live mainnet pre-upgrade) ----
        address ownerBefore = token.owner();
        bool pausedBefore = token.paused();
        bytes32 s304 = vm.load(TOKEN, bytes32(SLOT_DEFAULT_VALIDATOR));
        bytes32 s305 = vm.load(TOKEN, bytes32(SLOT_VALIDATOR_REGISTRY));
        bytes32 s306 = vm.load(TOKEN, bytes32(SLOT_CONTRACT_URI));
        address dvBefore = token.defaultValidator();
        address vrBefore = token.validatorRegistry();
        string memory cuBefore = token.contractURI();
        Prop memory p0 = _prop(ID0);
        Prop memory p1 = _prop(ID1);
        Prop memory p2 = _prop(ID2);
        uint256 balBefore = token.balanceOf(ID0_HOLDER, ID0);
        assertGt(p0.supply, 0, "precondition: ID0 is live");
        assertGt(balBefore, 0, "precondition: ID0_HOLDER holds ID0");
        console2.log("owner before:        ", ownerBefore);
        console2.log("paused before:       ", pausedBefore);
        console2.log("defaultValidator:    ", dvBefore);
        console2.log("validatorRegistry:   ", vrBefore);
        console2.log("ID0 supply/bal:      ", p0.supply, balBefore);

        // ---- APPLY the exact Safe multi-call ----
        address newImpl = address(new FabricaToken());
        _upgradeV4thenV5(newImpl);

        // ---- OWNER PRESERVED (the V4 migration's whole point) ----
        assertEq(token.owner(), ownerBefore, "owner() preserved through V4 owner migration");
        assertTrue(token.owner() != address(0), "owner() must not be address(0)");

        // ---- VERSION bumped 3 -> 5 (now in the v5 namespaced slot) ----
        assertEq(_initializedLowByte(INITIALIZABLE_V5_SLOT), 5, "_initialized bumped to 5");

        // ---- ALL DATA PRESERVED (raw slots + getters) ----
        assertEq(vm.load(TOKEN, bytes32(SLOT_DEFAULT_VALIDATOR)), s304, "slot 304 (_defaultValidator) raw preserved");
        assertEq(vm.load(TOKEN, bytes32(SLOT_VALIDATOR_REGISTRY)), s305, "slot 305 (_validatorRegistry) raw preserved");
        assertEq(vm.load(TOKEN, bytes32(SLOT_CONTRACT_URI)), s306, "slot 306 (_contractURI) raw preserved");
        assertEq(token.defaultValidator(), dvBefore, "defaultValidator() preserved (gap reads slot 304)");
        assertEq(token.validatorRegistry(), vrBefore, "validatorRegistry() preserved");
        assertEq(keccak256(bytes(token.contractURI())), keccak256(bytes(cuBefore)), "contractURI() preserved");
        assertTrue(_propPreserved(p0, _prop(ID0)), "ID0 _property preserved");
        assertTrue(_propPreserved(p1, _prop(ID1)), "ID1 _property preserved");
        assertTrue(_propPreserved(p2, _prop(ID2)), "ID2 _property preserved");
        assertEq(token.balanceOf(ID0_HOLDER, ID0), balBefore, "balanceOf preserved");
        assertEq(token.paused(), pausedBefore, "paused() preserved");

        // ---- INTENDED NEW BEHAVIOR ----
        assertEq(token.symbol(), "FABRICA", "symbol() == FABRICA (ENG-3226)");
        // basic supply==0 mint guard still works post-upgrade (origin/main lacks ENG-3145 _everMinted):
        // a fresh mint succeeds, and re-minting the same (minter, sessionId, operatingAgreement) reverts.
        address minter = makeAddr("preflight-minter");
        if (minter.code.length > 0) vm.etch(minter, "");
        uint256 sid = 987_654_321;
        string memory oaFresh = "ipfs://preflight-test-oa";
        vm.prank(minter);
        uint256 newId = token.mint(_one(minter), sid, _one(uint256(5)), "def", oaFresh, "{}", address(0));
        assertEq(token.balanceOf(minter, newId), 5, "fresh mint works post-upgrade");
        vm.prank(minter);
        vm.expectRevert("Session ID already exist, please use a different one");
        token.mint(_one(minter), sid, _one(uint256(1)), "def2", oaFresh, "{}", address(0));

        console2.log("owner after:         ", token.owner());
        console2.log("symbol after:        ", token.symbol());
        console2.log("_initialized after:  ", _initializedLowByte(INITIALIZABLE_V5_SLOT));
    }

    // ----------------------------------------------------------------------------------------------
    // 2) NEGATIVE CONTROL: the Sepolia-style V5-only path (skipping V4) BREAKS owner() -> proves V4
    //    is mandatory on mainnet.
    // ----------------------------------------------------------------------------------------------
    function test_mainnet_negativeControl_V5only_breaksOwner() public {
        if (_skip()) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);
        address ownerBefore = token.owner();
        assertTrue(ownerBefore != address(0), "precondition: owner set before");

        address newImpl = address(new FabricaToken());
        // upgrade + run ONLY initializeV5() (reinitializer(5) with _initialized==3 runs and skips V4).
        vm.prank(SAFE);
        (bool ok,) = TOKEN.call(
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)", newImpl, abi.encodeWithSignature("initializeV5()")
            )
        );
        assertTrue(ok, "V5-only upgrade call itself succeeds (which is the danger)");

        address ownerAfter = token.owner();
        console2.log("owner before:           ", ownerBefore);
        console2.log("owner after (V5-only):  ", ownerAfter);
        assertEq(ownerAfter, address(0), "NEGATIVE CONTROL: V5-only leaves owner() == address(0) -> V4 is MANDATORY");
    }

    // ----------------------------------------------------------------------------------------------
    // 3) uri() DEPENDENCY: the token upgrade preserves routing but uri() resolves ONLY once the
    //    ENG-3256 validator fix is also applied (token upgrade is not the uri() fix).
    // ----------------------------------------------------------------------------------------------
    function test_mainnet_uri_resolvesOnlyWithBothTokenAndValidatorFix() public {
        if (_skip()) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);

        _upgradeV4thenV5(address(new FabricaToken()));
        (,,,, address v0) = token._property(ID0);
        assertEq(v0, VALIDATOR, "ID0 routes to the default validator");

        // After the TOKEN upgrade ALONE, uri() still panics — the default validator is unfixed.
        (bool uriBefore,) = TOKEN.staticcall(abi.encodeWithSignature("uri(uint256)", ID0));
        assertFalse(uriBefore, "token upgrade alone: uri() still panics (validator unfixed)");

        // Apply the ENG-3256 validator fix too (impl already live on mainnet).
        (string[] memory uris, string[] memory names) = _strandedOAs();
        vm.prank(SAFE);
        (bool vok,) = VALIDATOR.call(
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)",
                VALIDATOR_IMPL,
                abi.encodeWithSignature("initializeV2(string,string[],string[])", VALIDATOR_BASEURI, uris, names)
            )
        );
        assertTrue(vok, "validator fix must apply");

        // Now the user-facing path resolves.
        (bool uriAfter, bytes memory ret) = TOKEN.staticcall(abi.encodeWithSignature("uri(uint256)", ID0));
        assertTrue(uriAfter, "uri() resolves once BOTH token upgrade and validator fix are applied");
        console2.log("uri(ID0) with both fixes:", abi.decode(ret, (string)));
    }

    // ---- helpers ----
    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _one(uint256 v) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = v;
    }

    function _strandedOAs() internal pure returns (string[] memory uris, string[] memory names) {
        uris = new string[](6);
        names = new string[](6);
        uris[0] = "ipfs://QmRH7d7TGJ3DymLSRimjnH5cNGHzYfcvUTUA1tM9gizFY8";
        uris[1] = "ipfs://QmXRQx7wPxSwQDVVr1pTkiwvBHBUd1SYLbLgSn1Bvirqpc";
        uris[2] = "ipfs://QmcgEJkgCwizvs6Tu12jCaNMGciRNtH8dLA2TRS3aYWStX";
        uris[3] = "ipfs://Qmf6Aia6gJfRgGyGroYft3kjxsLUhJEhMYVKPKj2JwY41Z";
        uris[4] = "ipfs://QmeRZqhU59Vpn4JQvggBVQ97uMfmS68utweUury8n5JLPR";
        uris[5] = "ipfs://QmNxY3ooc4VXbW6ETd1wVAxvajZYWu81U95MmWJiNBQw14";
        names[0] = "Fabrica US Trust v3.0";
        names[1] = "Fabrica US Trust v3.1";
        names[2] = "Fabrica US Trust v3.2";
        names[3] = "Fabrica US Trust v3.3";
        names[4] = "Fabrica US Trust v3.4";
        names[5] = "Fabrica US Trust v3.5";
    }
}
