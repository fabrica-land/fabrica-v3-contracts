// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IFabricaValidator} from "../src/IFabricaValidator.sol";
import {FabricaValidator} from "../src/FabricaValidator.sol";

/// @notice ENG-3007 DIAGNOSTIC (not a fix). Probes whether the default validator's `uri()`
/// storage-encoding panic (Panic 0x22) that canele found on Sepolia also affects MAINNET in its
/// CURRENT, pre-FabricaToken-v4/v5 state — or is Sepolia-only.
///
/// Run (both networks forked in-harness from foundry.toml rpc aliases; needs MAINNET_RPC_URL +
/// SEPOLIA_RPC_URL in the environment — `source .env` first):
///   forge test --match-contract FabricaValidatorUriProbeTest -vv
///
/// FINDING (verified against the on-chain upgrade log + Etherscan-verified impl sources):
/// The "default validator" is a SEPARATE UUPS contract from the FabricaToken proxy, with its OWN
/// upgrade history. The MAINNET validator proxy 0x1705…8ab0 was upgraded 3 times:
///   #1 block 17,928,566 -> impl 0x7ded932f… (solc 0.8.21, OZ v4 LINEAR, `__gap`)
///   #2 block 19,840,240 -> impl 0x33f1b766… (solc 0.8.25, OZ v4 LINEAR, `__gap`)
///   #3 block 24,344,085 -> impl 0x401f9b22… (solc 0.8.28, OZ v5 NAMESPACED, `erc7201`, NO `__gap`)
/// Upgrade #3 went live 2026-01-30T00:25:59Z. It swapped the validator to an OZ-v5 (ERC-7201
/// namespaced base storage) impl WITHOUT a `__legacy_gap`. Under the v4 impls the base contracts
/// consumed linear slots 0..200 (`_owner` at 151), so the custom vars lived at `_baseUri` slot 201,
/// `_operatingAgreementNames` slot 202, `_defaultOperatingAgreement` slot 203 — that real data is STILL
/// there (slot 201 = "https://metadata.fabrica.land/ethereum/0x5cbeb7…ea95/"). The v5 impl's bases
/// consume ZERO linear slots, so it now reads `_baseUri` at slot 0 — which still holds the v4
/// `Initializable._initialized = 1` leftover, an invalid string length. `uri()` =
/// `string.concat(_baseUri, toString(id))` therefore panics 0x22. Same on Sepolia's validator.
///
/// So this IS an OZ v4->v5 (namespaced-storage) migration bug, but it lives in the VALIDATOR, not
/// the token: the mainnet FabricaToken proxy 0x5cbeb…ea95 is STILL on OZ v4 (current impl
/// 0x7c26b9e4…, solc 0.8.26, `__gap`, not upgraded to v5). The pending ENG-3007 token upgrade
/// neither caused nor fixes this; the broken contract is the already-v5-migrated validator.
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

    // Original OZ-v4 linear slot of `_baseUri` (verified on mainnet): data is still physically here
    // (slot 201 = the live metadata URL), proving the WRITING impl used the v4 linear base layout.
    uint256 constant SLOT_BASEURI_V4 = 201;

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
        // The live impl reads owner() from the OZ-v5 ERC-7201 namespaced slot (not a linear slot),
        // which proves the CURRENT implementation is OZ v5.
        address ownerNamespaced = address(uint160(uint256(vm.load(validator, OWNABLE_V5_SLOT))));
        uint256 slot151 = uint256(vm.load(validator, bytes32(uint256(151)))); // validator's v4 _owner location
        (bool ok, bytes memory ret) = validator.staticcall(abi.encodeWithSignature("owner()"));
        address ownerGetter = ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);

        console2.log("--------------------------------------------------");
        console2.log(net);
        console2.log("  validator:                        ", validator);
        console2.log("  slot 0 (v4 _initialized leftover):", slot0);
        console2.log("  owner via v5 namespaced slot:     ", ownerNamespaced);
        console2.log("  raw slot 151 (v4 _owner location):", slot151);
        console2.log("  owner() getter:                   ", ownerGetter);

        assertEq(slot0, 1, "slot 0 must be the leftover v4 Initializable._initialized=1 (written by an OZ-v4 impl)");
        assertTrue(ownerNamespaced != address(0), "owner must live in the v5 ERC-7201 namespaced slot");
        assertEq(ownerGetter, ownerNamespaced, "owner() must read the v5 namespaced slot => live impl is OZ v5");
    }

    /// EMPIRICAL PROOF the running mainnet impl reads `_baseUri` at SLOT 0 — i.e. its base contracts
    /// occupy ZERO linear slots (OZ-v5 namespaced), NOT a sibling variable inserted before `_baseUri`
    /// in a v4-linear layout (which would leave `_baseUri` at slot 202 = the mapping slot = empty, no
    /// panic). We overwrite slot 0 with a valid short-string encoding on the fork; baseUri() then
    /// returning it proves the getter reads slot 0.
    function test_mainnet_runningImpl_readsBaseUriAtSlot0() public {
        if (_skipIfNoRpc("MAINNET_RPC_URL")) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);
        (bool okBefore,) = MAINNET_VALIDATOR.staticcall(abi.encodeWithSignature("baseUri()"));
        assertFalse(okBefore, "precondition: baseUri() panics as-is (reads slot 0 == malformed 1)");

        // OZ short-string encoding of "PROBE": data left-aligned in the high bytes, low byte = 2*len.
        bytes memory s = bytes("PROBE");
        bytes32 word;
        assembly {
            word := mload(add(s, 0x20))
        }
        bytes32 enc = word | bytes32(uint256(s.length * 2));
        vm.store(MAINNET_VALIDATOR, bytes32(uint256(0)), enc);

        (bool okAfter, bytes memory ret) = MAINNET_VALIDATOR.staticcall(abi.encodeWithSignature("baseUri()"));
        string memory got = okAfter ? abi.decode(ret, (string)) : "";
        console2.log("after vm.store(slot0, encode('PROBE')) -> baseUri() =", got);
        assertTrue(okAfter, "baseUri() must succeed after writing slot 0");
        assertEq(got, "PROBE", "running impl reads _baseUri at SLOT 0 => OZ-v5 namespaced base storage");
    }

    /// The real `_baseUri` data is intact at its ORIGINAL OZ-v4 linear slot 201; the v5 impl simply
    /// stops looking there (it reads slot 0). Recovers and logs the live metadata URL. (mainnet)
    function test_mainnet_baseUriData_orphanedAtV4Slot201() public {
        if (_skipIfNoRpc("MAINNET_RPC_URL")) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);
        uint256 lenMarker = uint256(vm.load(MAINNET_VALIDATOR, bytes32(SLOT_BASEURI_V4)));
        assertTrue(lenMarker != 0 && lenMarker % 2 == 1, "real _baseUri (long string) still lives at v4 slot 201");

        uint256 len = (lenMarker - 1) / 2;
        bytes32 dataLoc = keccak256(abi.encode(SLOT_BASEURI_V4));
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i * 32 < len; i++) {
            bytes32 wd = vm.load(MAINNET_VALIDATOR, bytes32(uint256(dataLoc) + i));
            for (uint256 j = 0; j < 32 && i * 32 + j < len; j++) {
                out[i * 32 + j] = wd[j];
            }
        }
        console2.log("recovered _baseUri @ v4 slot 201:", string(out));
        assertEq(
            uint256(vm.load(MAINNET_VALIDATOR, bytes32(uint256(0)))),
            1,
            "v5 read-slot (0) holds the malformed leftover 1"
        );
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

    // Exact pre-migration base URLs recovered from each validator's orphaned slot-201 data.
    string constant MAINNET_BASEURI =
        "https://metadata.fabrica.land/ethereum/0x5cbeb7a0df7ed85d82a472fd56d81ed550f3ea95/";
    string constant SEPOLIA_BASEURI =
        "https://metadata.fabrica.land/sepolia/0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD/";

    // A v5-era operating agreement (same CID + name on both networks) that already resolves and
    // therefore MUST NOT regress when we patch storage.
    string constant V5_OA_URI = "ipfs://bafkreihepeqissghiwo5zplcywrjlr6bfkgag5jm3jt5szxnsm6kptcpue";

    /// @dev The 6 pre-v5 operating-agreement names stranded at the old v4 mapping slot. Identical
    /// IPFS CIDs on mainnet and Sepolia (same underlying documents).
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

    /// Proves THE FIX: deploy the new impl and run initializeV2 atomically via upgradeToAndCall (the
    /// exact live tx). This SAME code path runs on whichever network's fork is selected. Asserts
    /// uri() is restored, the 6 stranded OA names are re-stored, and the live v5-era data
    /// (defaultOperatingAgreement + a v5-era OA name) is NOT regressed. No __legacy_gap.
    function _runValidatorUpgradeFix(string memory net, address val, address proxyAdmin, string memory baseUri)
        internal
    {
        (string[] memory uris, string[] memory names) = _strandedOAs();

        // --- BEFORE: uri() panics; snapshot non-regression observables. ---
        (bool uriBefore,) = val.staticcall(abi.encodeWithSignature("uri(uint256)", uint256(7)));
        assertFalse(uriBefore, "precondition: uri() panics before fix");
        string memory doaBefore = abi.decode(_staticOk(val, "defaultOperatingAgreement()"), (string));
        string memory v5NameBefore = _oaName(val, V5_OA_URI);
        assertGt(bytes(v5NameBefore).length, 0, "precondition: a v5-era OA resolves before");
        assertEq(bytes(_oaName(val, uris[0])).length, 0, "precondition: pre-v5 OA is stranded (empty) before");

        // --- APPLY: deploy new impl + upgradeToAndCall(initializeV2) atomically (the live tx). ---
        FabricaValidator newImpl = new FabricaValidator();
        bytes memory initData = abi.encodeWithSignature("initializeV2(string,string[],string[])", baseUri, uris, names);
        vm.prank(proxyAdmin);
        (bool ok,) = val.call(abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), initData));
        assertTrue(ok, "upgradeToAndCall(initializeV2) must succeed");

        // --- AFTER: uri() resolves. ---
        (bool uriAfter, bytes memory ur) = val.staticcall(abi.encodeWithSignature("uri(uint256)", uint256(7)));
        assertTrue(uriAfter, "uri() must no longer revert");
        assertEq(abi.decode(ur, (string)), string.concat(baseUri, "7"), "uri(7) = baseUri + id");
        console2.log(net, abi.decode(ur, (string)));

        // --- All 6 stranded OA names restored. ---
        for (uint256 i = 0; i < 6; i++) {
            assertEq(_oaName(val, uris[i]), names[i], "stranded OA name restored");
        }
        // --- NO REGRESSION: live v5-era data untouched. ---
        assertEq(_oaName(val, V5_OA_URI), v5NameBefore, "v5-era OA name unchanged");
        assertEq(abi.decode(_staticOk(val, "defaultOperatingAgreement()"), (string)), doaBefore, "defaultOA unchanged");
    }

    function test_sepolia_upgradeFix_fixesUri_restoresOAs_noRegression() public {
        if (_skipIfNoRpc("SEPOLIA_RPC_URL")) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("sepolia", SEPOLIA_BLOCK);
        _runValidatorUpgradeFix(
            "[SEPOLIA] fixed -> uri(7) =",
            SEPOLIA_VALIDATOR,
            0xBF03076547a99857b796717faF4034dea94569dF,
            SEPOLIA_BASEURI
        );
    }

    /// Same impl, same code path, on a MAINNET fork — proving the single parameterized fix is safe
    /// to ship to mainnet via the Safe (which we cannot broadcast from here; owner+proxyAdmin is a
    /// Safe contract 0x769586A6...). Validates the calldata that goes into the mainnet Safe tx.
    function test_mainnet_upgradeFix_fixesUri_restoresOAs_noRegression() public {
        if (_skipIfNoRpc("MAINNET_RPC_URL")) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_BLOCK);
        _runValidatorUpgradeFix(
            "[MAINNET] fixed -> uri(7) =",
            MAINNET_VALIDATOR,
            0x769586A65825B028b005176F1ebbd3B82bB07Fb0,
            MAINNET_BASEURI
        );
    }

    function _staticOk(address target, string memory sig) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok, "staticcall failed");
        return ret;
    }

    function _oaName(address val, string memory uri_) internal view returns (string memory) {
        (bool ok, bytes memory ret) = val.staticcall(abi.encodeWithSignature("operatingAgreementName(string)", uri_));
        require(ok, "operatingAgreementName failed");
        return abi.decode(ret, (string));
    }
}
