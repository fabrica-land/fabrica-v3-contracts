// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IFabricaValidator} from "../src/IFabricaValidator.sol";

/// @notice ENG-3007 DIAGNOSTIC (not a fix). Probes whether the default validator's `uri()`
/// storage-encoding panic (Panic 0x22) that canele found on Sepolia also affects MAINNET in its
/// CURRENT, pre-FabricaToken-v4/v5 state — or is Sepolia-only.
///
/// Run (both networks forked in-harness from foundry.toml rpc aliases; needs MAINNET_RPC_URL +
/// SEPOLIA_RPC_URL in the environment — `source .env` first):
///   forge test --match-contract FabricaValidatorUriProbeTest -vv
///
/// FINDING: the panic affects BOTH networks identically. The "default validator" is a SEPARATE
/// UUPS contract (its own proxy + impl) from the FabricaToken proxy. On BOTH mainnet and Sepolia
/// it has ALREADY been upgraded OZ v4 -> v5 WITHOUT the `__legacy_gap` storage-restoration fix that
/// FabricaToken received in ENG-2764, so its first custom string `_baseUri` now reads slot 0 —
/// which still holds the v4 `Initializable._initialized = 1` flag, an invalid string encoding —
/// and `uri()` (which is `string.concat(_baseUri, toString(id))`) panics 0x22. This is independent
/// of, and pre-dates, the pending ENG-3007 FabricaToken proxy upgrade.
contract FabricaValidatorUriProbeTest is Test {
    // FabricaToken proxies (UPGRADE-RUNBOOK.md "Network Addresses").
    address constant MAINNET_PROXY = 0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95;
    address constant SEPOLIA_PROXY = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;

    // `_defaultValidator` lives at OZ-v4 linear slot 304. That is its slot on mainnet (still
    // pre-upgrade / v4 layout) AND on Sepolia (FabricaToken's `__legacy_gap[301]` restores it to
    // 304 post-ENG-2764). One deployment-agnostic resolution works for both forks.
    uint256 constant SLOT_DEFAULT_VALIDATOR = 304;

    // Default validators resolved on-chain from slot 304 (cross-checked by the test).
    address constant MAINNET_VALIDATOR = 0x170511f95560A1F280c29026f73a9cD6a4bA8ab0;
    address constant SEPOLIA_VALIDATOR = 0xAAA7FDc1A573965a2eD47Ab154332b6b55098008;

    // Pinned recent blocks (apples-to-apples; both reproduce as of 2026-06-03, tips ~25.24M / ~10.98M).
    uint256 constant MAINNET_BLOCK = 25_237_000;
    uint256 constant SEPOLIA_BLOCK = 10_980_000;

    // Solidity Panic(uint256) selector and the "storage byte array incorrectly encoded" code.
    bytes4 constant PANIC_SELECTOR = 0x4e487b71;
    uint256 constant PANIC_STORAGE_ENCODING = 0x22;

    // OZ v5 ERC-7201 namespaced storage root for OwnableUpgradeable.
    bytes32 constant OWNABLE_V5_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    struct Probe {
        address validator;
        bool validatorUriOk; // did validator.uri(1) succeed?
        bytes validatorUriRet; // raw return-or-revert bytes
        bool tokenUriOk; // did FabricaToken.uri(1) succeed (user-facing path)?
        bytes tokenUriRet; // raw return-or-revert bytes
    }

    function _resolveDefaultValidator(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, bytes32(SLOT_DEFAULT_VALIDATOR)))));
    }

    /// @dev True iff `ret` is exactly `Panic(0x22)` — `abi.encodeWithSelector(0x4e487b71, 0x22)`.
    function _isStorageEncodingPanic(bytes memory ret) internal pure returns (bool) {
        if (ret.length != 36) return false;
        bytes4 sel;
        uint256 code;
        assembly {
            sel := mload(add(ret, 0x20))
            code := mload(add(ret, 0x24))
        }
        return sel == PANIC_SELECTOR && code == PANIC_STORAGE_ENCODING;
    }

    function _skipIfNoRpc(string memory key) internal view returns (bool) {
        return bytes(vm.envOr(key, string(""))).length == 0;
    }

    /// @dev Makes the SAME two raw calls on whichever fork is currently selected:
    ///   1) IFabricaValidator(defaultValidator).uri(1)  — the call canele saw panic on Sepolia
    ///   2) FabricaToken(proxy).uri(1)                   — the user-facing path, routes to default
    /// `uri()` ignores `id` for the panic (it reverts reading `_baseUri`), so id=1 is sufficient.
    function _probe(string memory net, address proxy, address expectedValidator) internal returns (Probe memory p) {
        p.validator = _resolveDefaultValidator(proxy);
        (p.validatorUriOk, p.validatorUriRet) =
            p.validator.staticcall(abi.encodeWithSelector(IFabricaValidator.uri.selector, uint256(1)));
        (p.tokenUriOk, p.tokenUriRet) = proxy.staticcall(abi.encodeWithSignature("uri(uint256)", uint256(1)));

        console2.log("==================================================");
        console2.log(net);
        console2.log("  FabricaToken proxy:           ", proxy);
        console2.log("  default validator (slot 304): ", p.validator);
        console2.log("  validator.uri(1) succeeded?   ", p.validatorUriOk);
        console2.log("  validator.uri(1) raw bytes:   ", vm.toString(p.validatorUriRet));
        console2.log("  FabricaToken.uri(1) succeeded?", p.tokenUriOk);
        console2.log("  FabricaToken.uri(1) raw bytes:", vm.toString(p.tokenUriRet));

        assertEq(p.validator, expectedValidator, "resolved default validator must match the known address");
    }

    // ----------------------------------------------------------------------------------------
    // CORE PROBE — does the default validator's uri() panic 0x22 on each network's CURRENT state?
    // ----------------------------------------------------------------------------------------

    function test_mainnet_defaultValidatorUri_panics0x22() public {
        if (_skipIfNoRpc("MAINNET_RPC_URL")) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);
        Probe memory p = _probe("[MAINNET] (pre-FabricaToken-v4/v5)", MAINNET_PROXY, MAINNET_VALIDATOR);

        assertFalse(p.validatorUriOk, "MAINNET: default validator uri() must revert");
        assertTrue(_isStorageEncodingPanic(p.validatorUriRet), "MAINNET: default validator uri() must panic 0x22");
        assertFalse(p.tokenUriOk, "MAINNET: FabricaToken.uri() (user-facing) must revert");
        assertTrue(_isStorageEncodingPanic(p.tokenUriRet), "MAINNET: FabricaToken.uri() must panic 0x22");
    }

    function test_sepolia_defaultValidatorUri_panics0x22() public {
        if (_skipIfNoRpc("SEPOLIA_RPC_URL")) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("sepolia", SEPOLIA_BLOCK);
        Probe memory p = _probe("[SEPOLIA] (post FabricaToken-v4/v5)", SEPOLIA_PROXY, SEPOLIA_VALIDATOR);

        assertFalse(p.validatorUriOk, "SEPOLIA: default validator uri() must revert");
        assertTrue(_isStorageEncodingPanic(p.validatorUriRet), "SEPOLIA: default validator uri() must panic 0x22");
        assertFalse(p.tokenUriOk, "SEPOLIA: FabricaToken.uri() (user-facing) must revert");
        assertTrue(_isStorageEncodingPanic(p.tokenUriRet), "SEPOLIA: FabricaToken.uri() must panic 0x22");
    }

    // ----------------------------------------------------------------------------------------
    // ROOT CAUSE — prove BOTH validators were UPGRADED OZ v4 -> v5 (not deployed fresh on v5),
    // which is what shifts `_baseUri` onto the v4 `_initialized` slot and causes the panic.
    // ----------------------------------------------------------------------------------------

    function _assertUpgradedV4ToV5(string memory net, address validator) internal {
        // slot 0 == 1: the OZ-v4 `Initializable._initialized` flag. No fresh-v5 deploy and no
        // setBaseUri() call could ever produce slot0 == 1 (it would be the `_baseUri` string slot,
        // which is 0 when empty). This is the fingerprint of an original v4 deployment.
        uint256 slot0 = uint256(vm.load(validator, bytes32(uint256(0))));
        // Owner now resolves via the v5 namespaced slot; the v4 `_owner` slot 101 is empty ->
        // the live implementation is OZ v5 and ran a v5 owner-migration.
        address ownerNamespaced = address(uint160(uint256(vm.load(validator, OWNABLE_V5_SLOT))));
        address ownerLegacy101 = address(uint160(uint256(vm.load(validator, bytes32(uint256(101))))));
        (bool ok, bytes memory ret) = validator.staticcall(abi.encodeWithSignature("owner()"));
        address ownerGetter = ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);

        console2.log("--------------------------------------------------");
        console2.log(net);
        console2.log("  validator:                        ", validator);
        console2.log("  slot 0 (expect v4 _initialized=1):", slot0);
        console2.log("  owner via v5 namespaced slot:     ", ownerNamespaced);
        console2.log("  owner via legacy v4 slot 101:     ", ownerLegacy101);
        console2.log("  owner() getter:                   ", ownerGetter);

        assertEq(slot0, 1, "slot 0 must be the leftover v4 Initializable._initialized=1 (v4 deployment fingerprint)");
        assertEq(ownerLegacy101, address(0), "v4 _owner slot 101 must be empty (owner migrated off it)");
        assertTrue(ownerNamespaced != address(0), "owner must live in the v5 ERC-7201 namespaced slot");
        assertEq(ownerGetter, ownerNamespaced, "owner() must read the v5 namespaced slot => live impl is OZ v5");
    }

    function test_bothValidators_wereUpgradedV4ToV5() public {
        if (!_skipIfNoRpc("MAINNET_RPC_URL")) {
            vm.createSelectFork("mainnet", MAINNET_BLOCK);
            _assertUpgradedV4ToV5("[MAINNET validator upgrade fingerprint]", MAINNET_VALIDATOR);
        }
        if (!_skipIfNoRpc("SEPOLIA_RPC_URL")) {
            vm.createSelectFork("sepolia", SEPOLIA_BLOCK);
            _assertUpgradedV4ToV5("[SEPOLIA validator upgrade fingerprint]", SEPOLIA_VALIDATOR);
        }
    }
}
