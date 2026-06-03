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
/// Forks the real network, deploys the NEW `_everMinted` implementation, upgrades the live proxy
/// via the real (empty-data) upgrade path, and exercises the guard against actual on-chain state.
///
/// Run: forge test --match-contract FabricaTokenForkUpgradeTest \
///        --fork-url $SEPOLIA_RPC_URL -vvv
///
/// The Sepolia proxy is already at reinitializer v5 (storage-gap + symbol deployed), and the
/// `_everMinted` mapping needs no migration (defaults to false), so the upgrade carries EMPTY
/// calldata — mirroring the exact production-rollout transaction.
contract FabricaTokenForkUpgradeTest is Test {
    address constant PROXY = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    address constant PROXY_ADMIN = 0xBF03076547a99857b796717faF4034dea94569dF;
    uint256 constant SLOT_EVER_MINTED = 307;
    // Pin the fork to a fixed Sepolia block so the LIVE_* fixtures (liveness, metadata) are
    // deterministic and the suite cannot go flaky as Sepolia advances. At this block: impl ==
    // 0x0106BC5A025996E0D67f893F0f9F47be87ED510a (v5/symbol build), LIVE_ID & LIVE_ID_2 supply == 1,
    // and LIVE_DEF/LIVE_OA match. Verified on-chain.
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

    function _everMintedSlot(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, SLOT_EVER_MINTED));
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

    /// Steps (1)+(2): take the LIVE proxy, deploy the NEW impl, upgrade via the real path.
    function _upgradeToNewImpl() internal returns (address newImpl) {
        newImpl = address(new FabricaToken());
        vm.prank(PROXY_ADMIN);
        token.upgradeToAndCall(newImpl, "");
        assertEq(token.implementation(), newImpl, "proxy should point at the new _everMinted impl");
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

    /// (3) Upgrade preserves existing storage, and _everMinted reads false for all pre-upgrade ids.
    function test_fork_upgrade_preservesStorage_and_everMintedFalse() public onlyFork {
        // --- pre-upgrade snapshot ---
        Snap memory before = _snap(LIVE_ID);
        (uint256 sup0b,,,,) = token._property(LIVE_ID_2);
        address ownerBefore = token.owner();
        address regBefore = token.validatorRegistry();
        string memory uriBefore = token.contractURI();
        assertGt(before.supply, 0, "precondition: LIVE_ID must be live (supply > 0)");
        // _everMinted is false BEFORE the upgrade (slot does not exist yet on the deployed impl).
        assertEq(uint256(vm.load(PROXY, _everMintedSlot(LIVE_ID))), 0, "everMinted pre-upgrade must read 0");

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

        // _everMinted reads false for pre-upgrade ids (no backfill; new slot 307 starts empty).
        assertEq(uint256(vm.load(PROXY, _everMintedSlot(LIVE_ID))), 0, "everMinted must be 0 for pre-upgrade LIVE_ID");
        assertEq(
            uint256(vm.load(PROXY, _everMintedSlot(LIVE_ID_2))), 0, "everMinted must be 0 for pre-upgrade LIVE_ID_2"
        );
    }

    /// (4a) A REAL pre-upgrade LIVE token cannot be re-minted: the `supply == 0` term protects it
    /// even though its `_everMinted` flag is false post-upgrade. This is the upgrade-safety case.
    function test_fork_4a_preUpgradeLiveToken_remintReverts() public onlyFork {
        _upgradeToNewImpl();
        // The id is genuinely reproducible from the original (minter, sessionId, operatingAgreement).
        assertEq(token.generateId(LIVE_MINTER, LIVE_SESSION_ID, LIVE_OA), LIVE_ID, "id must reproduce");
        (uint256 sup,, string memory defBefore,,) = token._property(LIVE_ID);
        assertGt(sup, 0, "token must be live");
        assertEq(uint256(vm.load(PROXY, _everMintedSlot(LIVE_ID))), 0, "everMinted false (pre-upgrade)");

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

    /// (4b) A token minted AFTER the upgrade, burned to zero, cannot be re-minted (`!_everMinted`).
    function test_fork_4b_postUpgradeBurnRemint_reverts() public onlyFork {
        _upgradeToNewImpl();
        address minter = _newEOA("fork-4b-minter");
        vm.prank(minter);
        uint256 id = token.mint(
            _single(minter), 4337, _single(uint256(10)), "ipfs://def-A", "ipfs://oa-fork-b", "{}", address(0)
        );
        assertEq(uint256(vm.load(PROXY, _everMintedSlot(id))), 1, "everMinted set after post-upgrade mint");

        vm.prank(minter);
        token.burn(minter, id, 10);
        (uint256 supAfterBurn,,,,) = token._property(id);
        assertEq(supAfterBurn, 0, "burned to zero");

        // Re-mint the same id (same minter+sessionId+OA) must revert on the _everMinted flag.
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
}
