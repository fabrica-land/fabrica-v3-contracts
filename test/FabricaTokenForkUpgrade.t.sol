// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {IFabricaValidator} from "../src/IFabricaValidator.sol";

/// @dev Minimal validator whose uri() returns a fixed string. Used as a stand-in default
/// validator on the fork because the REAL Sepolia default validator's uri() reverts with a
/// pre-existing storage-encoding panic (unrelated to ENG-3145 — `_property` reads fine and this
/// PR does not touch uri()). The mock lets us assert the validator-resolution ROUTING that
/// ENG-3145 must preserve, without depending on that broken external rendering.
contract ForkMockValidator is IFabricaValidator {
    string private _u;

    constructor(string memory u) {
        _u = u;
    }

    function uri(uint256) external view returns (string memory) {
        return _u;
    }

    function defaultOperatingAgreement() external pure returns (string memory) {
        return "ipfs://mock-default-oa";
    }

    function operatingAgreementName(string memory) external pure returns (string memory) {
        return "MockOA";
    }
}

/// @notice ENG-3145 fork-deploy UPGRADE functional verification against the LIVE Sepolia proxy.
/// Forks the real network, deploys the NEW definition-guard implementation, upgrades the live
/// proxy via the real V6 path (`initializeV6`, 5 -> 6), and exercises the guard against actual
/// on-chain state.
///
/// Run: forge test --match-contract FabricaTokenForkUpgradeTest \
///        --fork-url $SEPOLIA_RPC_URL -vvv
///
/// The Sepolia proxy is already at reinitializer v5 (storage-gap + symbol deployed). ENG-3145
/// adds no storage migration; the upgrade calldata is `initializeV6()` — the empty version-stamp
/// reinitializer that bumps 5 -> 6 and makes the upgrade one-shot. This mirrors the exact
/// production-rollout transaction for Sepolia.
contract FabricaTokenForkUpgradeTest is Test {
    address constant PROXY = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    address constant PROXY_ADMIN = 0xBF03076547a99857b796717faF4034dea94569dF;
    uint256 constant SLOT_PROPERTY = 303;
    uint256 constant SLOT_FREE_307 = 307;
    // OZ v5 ERC-7201 namespaced slot for Initializable._initialized.
    bytes32 constant OZ_V5_INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    // Pin the fork to a fixed Sepolia block so the LIVE_* fixtures (liveness, metadata) are
    // deterministic and the suite cannot go flaky as Sepolia advances. At this block: impl ==
    // 0x0106BC5A025996E0D67f893F0f9F47be87ED510a (v5/symbol build), _initialized == 5,
    // LIVE_ID & LIVE_ID_2 supply == 1, and LIVE_DEF/LIVE_OA match. Verified on-chain.
    uint256 constant FORK_BLOCK = 10_977_800;

    // A REAL, currently-LIVE pre-upgrade token discovered on Sepolia. The id is verified to be
    // reproducible: generateId(LIVE_MINTER, LIVE_SESSION_ID, LIVE_OA) == LIVE_ID on-chain.
    uint256 constant LIVE_ID = 15783036582722607647; // 0xdb089c265e2d1a1f
    address constant LIVE_MINTER = 0xd4BcEF536cf062cA7b14A736EE65E6B6E1690837;
    uint256 constant LIVE_SESSION_ID = 46539036421554536015528387045323411820195691147061328631213616222090615984749;
    string constant LIVE_OA = "ipfs://bafkreihkphcet3ncjlmd7kv4wgc32ot3mnkpudavtydnwt4hdaa3q5z6mi";
    string constant LIVE_DEF = "ipfs://bafkreiaj3awqmhnbiiepevly676uz2hapgeghchvv34xsm3t525u523u4e";
    // A second real live token, used to widen the storage-preservation assertion.
    uint256 constant LIVE_ID_2 = 0xe6b5cd940c8b7c64;

    FabricaToken token;

    modifier onlyFork() {
        // No code at the proxy => not running with --fork-url; skip silently.
        if (PROXY.code.length == 0) return;
        _;
    }

    function setUp() public {
        // Pin to a fixed block when running on a fork so live-state assertions are deterministic.
        // Skipped when not forking (no active fork => PROXY has no code, and rollFork would revert).
        if (PROXY.code.length > 0) {
            vm.rollFork(FORK_BLOCK);
        }
        token = FabricaToken(PROXY);
    }

    /// @dev makeAddr results can collide with contracts already deployed on the fork, which would
    /// break ERC-1155 receiver-acceptance callbacks. Force the address to be a clean EOA.
    function _ensureEOA(address addr) internal {
        if (addr.code.length > 0) vm.etch(addr, "");
    }

    function _propertyBaseSlot(uint256 id) internal pure returns (bytes32) {
        // Property struct base slot; offset +0 is `supply`.
        return keccak256(abi.encode(id, SLOT_PROPERTY));
    }

    function _initializedVersion() internal view returns (uint256) {
        return uint256(vm.load(PROXY, OZ_V5_INITIALIZABLE_SLOT)) & 0xff;
    }

    struct Snap {
        uint256 supply;
        string oa;
        string def;
        string cfg;
        address val;
    }

    function _snap(uint256 id) internal view returns (Snap memory s) {
        (s.supply, s.oa, s.def, s.cfg, s.val) = token._property(id);
    }

    /// Steps (1)+(2): take the LIVE proxy, deploy the NEW impl, upgrade via the real V6 path.
    function _upgradeToNewImpl() internal returns (address newImpl) {
        assertEq(_initializedVersion(), 5, "fork precondition: proxy at _initialized = 5");
        newImpl = address(new FabricaToken());
        vm.prank(PROXY_ADMIN);
        token.upgradeToAndCall(newImpl, abi.encodeCall(FabricaToken.initializeV6, ()));
        assertEq(token.implementation(), newImpl, "proxy should point at the new definition-guard impl");
        assertEq(_initializedVersion(), 6, "upgrade must bump _initialized to 6");
    }

    function _newEOA(string memory label) internal returns (address a) {
        a = makeAddr(label);
        _ensureEOA(a);
    }

    function _single(address who) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = who;
    }

    function _single(uint256 v) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = v;
    }

    /// (3) Upgrade preserves existing storage, bumps version to 6, and leaves slot 307 free.
    function test_fork_upgrade_preservesStorage() public onlyFork {
        // --- pre-upgrade snapshot ---
        Snap memory before = _snap(LIVE_ID);
        (uint256 sup0b,,,,) = token._property(LIVE_ID_2);
        address ownerBefore = token.owner();
        address regBefore = token.validatorRegistry();
        string memory uriBefore = token.contractURI();
        assertGt(before.supply, 0, "precondition: LIVE_ID must be live (supply > 0)");

        // --- upgrade ---
        _upgradeToNewImpl();

        // --- storage preserved post-upgrade ---
        Snap memory afterSnap = _snap(LIVE_ID);
        assertEq(afterSnap.supply, before.supply, "supply preserved");
        assertEq(afterSnap.oa, before.oa, "operatingAgreement preserved");
        assertEq(afterSnap.def, before.def, "definition preserved");
        assertEq(afterSnap.cfg, before.cfg, "configuration preserved");
        assertEq(afterSnap.val, before.val, "validator preserved");
        (uint256 sup1b,,,,) = token._property(LIVE_ID_2);
        assertEq(sup1b, sup0b, "second token supply preserved");
        assertEq(token.validatorRegistry(), regBefore, "validatorRegistry preserved");
        assertEq(token.contractURI(), uriBefore, "contractURI preserved");
        assertEq(token.owner(), ownerBefore, "owner preserved");

        // Slot 307 stays FREE — the definition-based guard appends no storage variable.
        assertEq(uint256(vm.load(PROXY, bytes32(SLOT_FREE_307))), 0, "slot 307 base must remain free");
        assertEq(
            uint256(vm.load(PROXY, keccak256(abi.encode(LIVE_ID, SLOT_FREE_307)))),
            0,
            "no per-id slot-307 data may be written"
        );
    }

    /// (4a) A REAL pre-upgrade LIVE token cannot be re-minted — its non-empty on-chain
    /// `definition` is the guard marker, independent of supply.
    function test_fork_4a_preUpgradeLiveToken_remintReverts() public onlyFork {
        _upgradeToNewImpl();
        // The id is genuinely reproducible from the original (minter, sessionId, operatingAgreement).
        assertEq(token.generateId(LIVE_MINTER, LIVE_SESSION_ID, LIVE_OA), LIVE_ID, "id must reproduce");
        (uint256 sup,, string memory defBefore,,) = token._property(LIVE_ID);
        assertGt(sup, 0, "token must be live");
        assertEq(defBefore, LIVE_DEF, "fixture matches the on-chain definition");
        assertGt(bytes(defBefore).length, 0, "live token has a non-empty definition (the guard marker)");

        // The original minter attempts to re-mint the same id with a NEW definition.
        vm.prank(LIVE_MINTER);
        vm.expectRevert("Session ID already exist, please use a different one");
        token.mint(
            _single(LIVE_MINTER),
            LIVE_SESSION_ID,
            _single(uint256(1)),
            "ipfs://EVIL-OVERWRITE",
            LIVE_OA,
            "{}",
            address(0)
        );

        // Property is untouched: definition not overwritten.
        (,, string memory defAfter,,) = token._property(LIVE_ID);
        assertEq(defAfter, defBefore, "live token definition must NOT be overwritten");
    }

    /// (4b) A token minted AFTER the upgrade, burned to zero, cannot be re-minted — the definition
    /// survives the burn and blocks the remint.
    function test_fork_4b_postUpgradeBurnRemint_reverts() public onlyFork {
        _upgradeToNewImpl();
        address minter = _newEOA("fork-4b-minter");
        vm.prank(minter);
        uint256 id = token.mint(
            _single(minter), 4337, _single(uint256(10)), "ipfs://def-A", "ipfs://oa-fork-b", "{}", address(0)
        );

        vm.prank(minter);
        token.burn(minter, id, 10);
        (uint256 supAfterBurn,, string memory defAfterBurn,,) = token._property(id);
        assertEq(supAfterBurn, 0, "burned to zero");
        assertEq(defAfterBurn, "ipfs://def-A", "definition survives the burn (the guard marker)");

        // Re-mint the same id (same minter+sessionId+OA) must revert on the definition guard.
        vm.prank(minter);
        vm.expectRevert("Session ID already exist, please use a different one");
        token.mint(_single(minter), 4337, _single(uint256(5)), "ipfs://def-B", "ipfs://oa-fork-b", "{}", address(0));
    }

    /// (4c) Minting with validator == address(0) resolves to the default validator (semantics
    /// intact), and uri() for the new token routes through that default validator. We install a
    /// working mock as the default validator because the real Sepolia default validator's uri()
    /// has a pre-existing storage panic (see ForkMockValidator note).
    function test_fork_4c_defaultValidator_mint_and_uri() public onlyFork {
        _upgradeToNewImpl();
        ForkMockValidator mockDefault = new ForkMockValidator("ipfs://mock-default-uri");
        vm.prank(token.owner());
        token.setDefaultValidator(address(mockDefault));

        address minter = _newEOA("fork-4c-minter");
        vm.prank(minter);
        // validator == address(0) => must resolve to the (mock) default validator.
        uint256 id = token.mint(
            _single(minter), 5151, _single(uint256(5)), "ipfs://def-C", "ipfs://oa-fork-c", "{}", address(0)
        );
        (uint256 sup,,,, address storedVal) = token._property(id);
        assertEq(sup, 5, "mint succeeded with supply 5");
        assertEq(storedVal, address(mockDefault), "validator=0 must resolve to the default validator");
        // uri() routes through the default validator.
        assertEq(token.uri(id), "ipfs://mock-default-uri", "uri() must resolve via the default validator");
    }

    /// (4d) updateValidator(address(0)) still works (reset-to-default is NOT bricked): after an
    /// explicit validator is reset to 0, uri() falls back to the default validator. Validator
    /// semantics that ENG-3145 must NOT break.
    function test_fork_4d_updateValidatorZero_notBricked() public onlyFork {
        _upgradeToNewImpl();
        ForkMockValidator mockDefault = new ForkMockValidator("ipfs://mock-default-uri");
        ForkMockValidator mockExplicit = new ForkMockValidator("ipfs://mock-explicit-uri");
        vm.prank(token.owner());
        token.setDefaultValidator(address(mockDefault));

        address minter = _newEOA("fork-4d-minter");
        vm.prank(minter);
        // Mint with an EXPLICIT validator so the reset-to-default is observable.
        uint256 id = token.mint(
            _single(minter),
            6262,
            _single(uint256(100)),
            "ipfs://def-D",
            "ipfs://oa-fork-d",
            "{}",
            address(mockExplicit)
        );
        assertEq(token.uri(id), "ipfs://mock-explicit-uri", "uri uses the explicit validator before reset");

        // The 100% owner resets the validator to address(0) — must succeed and not brick uri().
        vm.prank(minter);
        bool ok = token.updateValidator(address(0), id);
        assertTrue(ok, "updateValidator(0) must return true");
        (,,,, address vAfter) = token._property(id);
        assertEq(vAfter, address(0), "validator must be reset to address(0)");
        // With stored validator == address(0), uri() falls back to the default validator.
        assertEq(token.uri(id), "ipfs://mock-default-uri", "uri() must fall back to the default validator after reset");
    }

    /// (4e) THE GAP THIS PR CLOSES, on REAL pre-upgrade storage: a token that existed before the
    /// upgrade and is then FULLY BURNED post-upgrade cannot be re-minted. The earlier _everMinted
    /// approach left this open — the pre-upgrade id's flag was never set, so a post-upgrade burn
    /// dropped supply to 0 and the id became re-mintable. The definition-based guard blocks it
    /// because `_burn` never clears the (real, on-chain) `definition`. We model the full burn by
    /// zeroing LIVE_ID's supply slot directly; the rest of its real pre-upgrade `_property`
    /// (definition included) is left exactly as deployed.
    function test_fork_4e_preUpgradeLiveToken_burnedThenRemintReverts() public onlyFork {
        _upgradeToNewImpl();
        assertEq(token.generateId(LIVE_MINTER, LIVE_SESSION_ID, LIVE_OA), LIVE_ID, "id must reproduce");
        (uint256 sup,, string memory defBefore,,) = token._property(LIVE_ID);
        assertGt(sup, 0, "precondition: live");
        assertEq(defBefore, LIVE_DEF, "precondition: real definition present");

        // Simulate a full post-upgrade burn: supply -> 0 (struct offset +0); definition untouched.
        vm.store(PROXY, _propertyBaseSlot(LIVE_ID), bytes32(uint256(0)));
        (uint256 supAfter,, string memory defStill,,) = token._property(LIVE_ID);
        assertEq(supAfter, 0, "burned to zero");
        assertEq(defStill, defBefore, "definition persists through the burn");

        // Re-minting the now-burned pre-upgrade id must revert on the definition guard.
        vm.prank(LIVE_MINTER);
        vm.expectRevert("Session ID already exist, please use a different one");
        token.mint(
            _single(LIVE_MINTER),
            LIVE_SESSION_ID,
            _single(uint256(1)),
            "ipfs://EVIL-OVERWRITE",
            LIVE_OA,
            "{}",
            address(0)
        );

        (,, string memory defFinal,,) = token._property(LIVE_ID);
        assertEq(defFinal, defBefore, "definition must remain untouched after the blocked remint");
    }
}
