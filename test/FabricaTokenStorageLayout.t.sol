// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {FabricaProxy} from "../src/FabricaProxy.sol";
import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";
import {FabricaValidator} from "../src/FabricaValidator.sol";
import {FabricaValidatorRegistry} from "../src/FabricaValidatorRegistry.sol";
import {FabricaTokenUpgradeScript, TokenImplementation, TokenProxy} from "../script/FabricaTokenUpgrade.s.sol";

contract MockDefaultValidatorOnly {
    function defaultValidator() external pure returns (address) {
        return address(0);
    }
}

/// @notice Verifies the FabricaToken storage layout matches the original OZ v4 slot positions.
/// The __legacy_gap[301] must keep all state variables at their historical proxy storage slots.
contract FabricaTokenStorageLayoutTest is Test {
    FabricaToken public token;
    address public proxy;
    address public proxyAdmin;
    FabricaValidator public validator;
    FabricaValidatorRegistry public registry;
    // Expected slot positions (from OZ v4 era, verified on-chain)
    uint256 constant SLOT_BALANCES = 301;
    uint256 constant SLOT_OPERATOR_APPROVALS = 302;
    uint256 constant SLOT_PROPERTY = 303;
    uint256 constant SLOT_DEFAULT_VALIDATOR = 304;
    uint256 constant SLOT_VALIDATOR_REGISTRY = 305;
    uint256 constant SLOT_CONTRACT_URI = 306;
    // ENG-3145: slot 307 is intentionally left FREE — the burn-remint guard reuses
    // _property[id].definition rather than appending a new state variable.
    uint256 constant SLOT_FREE_307 = 307;
    // OZ v5 ERC-7201 namespaced slot for OwnableUpgradeable._owner
    bytes32 constant OZ_V5_OWNER_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;
    // OZ v5 ERC-7201 namespaced slot for Initializable._initialized
    bytes32 constant OZ_V5_INITIALIZABLE_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    bytes32 constant ERC1967_IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address constant FORGE_DEFAULT_BROADCASTER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    function setUp() public {
        proxyAdmin = makeAddr("proxyAdmin");
        // Deploy validator and registry for mint operations
        FabricaValidator validatorImpl = new FabricaValidator();
        FabricaProxy validatorProxy =
            new FabricaProxy(address(validatorImpl), proxyAdmin, abi.encodeCall(FabricaValidator.initialize, ()));
        validator = FabricaValidator(address(validatorProxy));
        FabricaValidatorRegistry registryImpl = new FabricaValidatorRegistry();
        FabricaProxy registryProxy = new FabricaProxy(
            address(registryImpl), proxyAdmin, abi.encodeCall(FabricaValidatorRegistry.initialize, ())
        );
        registry = FabricaValidatorRegistry(address(registryProxy));
        // Deploy FabricaToken
        FabricaToken impl = new FabricaToken();
        FabricaProxy proxyContract =
            new FabricaProxy(address(impl), proxyAdmin, abi.encodeCall(FabricaToken.initialize, ()));
        proxy = address(proxyContract);
        token = FabricaToken(proxy);
        // Set owner and configure
        vm.startPrank(token.owner());
        token.setDefaultValidator(address(validator));
        token.setValidatorRegistry(address(registry));
        token.setContractURI("https://example.com/contract-uri");
        vm.stopPrank();
    }

    function test_defaultValidator_atSlot304() public view {
        bytes32 stored = vm.load(proxy, bytes32(SLOT_DEFAULT_VALIDATOR));
        assertEq(address(uint160(uint256(stored))), address(validator), "_defaultValidator not at expected slot 304");
    }

    function test_validatorRegistry_atSlot305() public view {
        bytes32 stored = vm.load(proxy, bytes32(SLOT_VALIDATOR_REGISTRY));
        assertEq(address(uint160(uint256(stored))), address(registry), "_validatorRegistry not at expected slot 305");
    }

    function test_contractURI_atSlot306() public view {
        string memory uri = "https://example.com/contract-uri";
        // Verify via public function that the stored value matches
        assertEq(token.contractURI(), uri, "contractURI should match");
        // Verify the raw storage slot is non-zero at the expected position
        bytes32 stored = vm.load(proxy, bytes32(SLOT_CONTRACT_URI));
        uint256 raw = uint256(stored);
        // For strings > 31 bytes, Solidity stores (length * 2 + 1) at the base slot.
        uint256 expected = bytes(uri).length * 2 + 1;
        assertEq(raw, expected, "_contractURI slot 306 should store long-string length encoding");
    }

    function test_balances_atSlot301() public {
        // Mint a token and check the balance is at the correct slot
        address recipient = makeAddr("recipient");
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000;
        vm.prank(recipient);
        uint256 tokenId = token.mint(recipients, 1, amounts, "test-definition", "", "", address(0));
        // Verify via public function
        assertEq(token.balanceOf(recipient, tokenId), 1000, "balanceOf should return 1000");
        // Verify storage slot: _balances is at slot 301
        // For mapping(uint256 => mapping(address => uint256)):
        // slot = keccak256(account . keccak256(tokenId . 301))
        bytes32 innerSlot = keccak256(abi.encode(tokenId, SLOT_BALANCES));
        bytes32 balanceSlot = keccak256(abi.encode(recipient, innerSlot));
        uint256 rawBalance = uint256(vm.load(proxy, balanceSlot));
        assertEq(rawBalance, 1000, "_balances not at expected slot 301");
    }

    function test_operatorApprovals_atSlot302() public {
        address approver = makeAddr("approver");
        address operator = makeAddr("operator");
        vm.prank(approver);
        token.setApprovalForAll(operator, true);
        // Verify via public function
        assertTrue(token.isApprovedForAll(approver, operator), "isApprovedForAll should be true");
        // Verify storage slot: _operatorApprovals is at slot 302
        // For mapping(address => mapping(address => bool)):
        // slot = keccak256(operator . keccak256(approver . 302))
        bytes32 innerSlot = keccak256(abi.encode(approver, SLOT_OPERATOR_APPROVALS));
        bytes32 approvalSlot = keccak256(abi.encode(operator, innerSlot));
        uint256 rawApproval = uint256(vm.load(proxy, approvalSlot));
        assertEq(rawApproval, 1, "_operatorApprovals not at expected slot 302");
    }

    function test_property_atSlot303() public {
        // Mint a token to create a property entry
        address recipient = makeAddr("recipient");
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        vm.prank(recipient);
        uint256 tokenId = token.mint(recipients, 2, amounts, "test-definition", "", "", address(0));
        // Property struct: first field is `supply` (uint256)
        // For mapping(uint256 => Property), the struct base slot is:
        // keccak256(tokenId . 303)
        bytes32 propertyBaseSlot = keccak256(abi.encode(tokenId, SLOT_PROPERTY));
        uint256 rawSupply = uint256(vm.load(proxy, propertyBaseSlot));
        assertEq(rawSupply, 100, "_property.supply not at expected slot 303");
    }

    function test_slot307_isFree() public {
        // ENG-3145 dropped the transient _everMinted mapping; slot 307 (and its keccak-derived
        // per-id slots) must remain UNTOUCHED by mint. The burn-remint guard now keys on
        // _property[id].definition (slot 303), so nothing is appended after _contractURI (306).
        address recipient = makeAddr("recipient");
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100;
        bytes32 contractUriBefore = vm.load(proxy, bytes32(SLOT_CONTRACT_URI));
        vm.prank(recipient);
        uint256 tokenId = token.mint(recipients, 7, amounts, "test-definition", "", "", address(0));
        // Base slot 307 and the per-id slot keccak256(id . 307) are both zero — nothing lives there.
        assertEq(uint256(vm.load(proxy, bytes32(SLOT_FREE_307))), 0, "slot 307 base must be free");
        bytes32 perIdSlot = keccak256(abi.encode(tokenId, SLOT_FREE_307));
        assertEq(uint256(vm.load(proxy, perIdSlot)), 0, "no per-id data may be written at slot 307");
        // _contractURI (306) — the last used variable — is undisturbed by the mint.
        assertEq(vm.load(proxy, bytes32(SLOT_CONTRACT_URI)), contractUriBefore, "_contractURI slot 306 disturbed");
    }

    function test_initializeV4_migratesOwner() public {
        // Set up a fresh proxy simulating the OZ v4→v5 state
        address expectedOwner = makeAddr("expectedOwner");
        (FabricaToken freshToken,) = _freshTokenWithLegacyOwner(expectedOwner);
        // Owner in legacy slot 101, zeroed in ERC-7201 slot
        assertEq(freshToken.owner(), address(0), "Owner should be zero before V4 migration");
        // Run initializeV4 (owner migration)
        vm.prank(proxyAdmin);
        freshToken.initializeV4();
        assertEq(freshToken.owner(), expectedOwner, "Owner should be migrated by initializeV4");
    }

    function test_initializeV5_isNoOp() public {
        // V5 is a no-op that just bumps the reinitializer version.
        // After V4 migrates the owner, V5 should not change it.
        address expectedOwner = makeAddr("expectedOwner");
        (FabricaToken freshToken,) = _freshTokenWithLegacyOwner(expectedOwner);
        // Run V4 first (owner migration)
        vm.prank(proxyAdmin);
        freshToken.initializeV4();
        assertEq(freshToken.owner(), expectedOwner, "Owner should be set after V4");
        // Run V5 (no-op)
        vm.prank(proxyAdmin);
        freshToken.initializeV5();
        assertEq(freshToken.owner(), expectedOwner, "Owner should be unchanged after V5");
    }

    function test_initializeV5_revertsForNonAdmin() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert("FabricaUUPSUpgradeable: caller is not the proxy admin");
        token.initializeV5();
    }

    function test_initializeV5_cannotBeCalledTwice() public {
        _assertInitializerCannotBeCalledTwice(false);
    }

    function test_initializeV6_isNoOp() public {
        // V6 (ENG-3145) is a no-op version stamp — it must not change any state.
        (FabricaToken freshToken,) = _freshToken(proxyAdmin);
        address ownerBefore = freshToken.owner();
        vm.prank(proxyAdmin);
        freshToken.initializeV6();
        assertEq(freshToken.owner(), ownerBefore, "Owner should be unchanged after V6");
    }

    function test_initializeV6_revertsForNonAdmin() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert("FabricaUUPSUpgradeable: caller is not the proxy admin");
        token.initializeV6();
    }

    function test_initializeV6_cannotBeCalledTwice() public {
        _assertInitializerCannotBeCalledTwice(true);
    }

    function test_mainnetUpgradePath_V4thenV5thenV6() public {
        // Mainnet/Base Sepolia (ENG-3145) path: V4 (owner migration) + V5 + V6 (version bumps).
        address expectedOwner = makeAddr("expectedOwner");
        (FabricaToken freshToken, address freshProxyAddr) = _freshTokenWithLegacyOwner(expectedOwner);
        // Deploy new implementation and upgrade with V4 (owner migration).
        FabricaToken newImpl = new FabricaToken();
        vm.prank(proxyAdmin);
        freshToken.upgradeToAndCall(address(newImpl), abi.encodeCall(FabricaToken.initializeV4, ()));
        assertEq(freshToken.owner(), expectedOwner, "Owner should be migrated after V4 upgrade");
        assertEq(freshToken.implementation(), address(newImpl), "Implementation should be updated");
        // Then V5 (no-op bump), then V6 (ENG-3145 no-op version stamp).
        vm.prank(proxyAdmin);
        freshToken.initializeV5();
        assertEq(freshToken.owner(), expectedOwner, "Owner unchanged after V5");
        vm.prank(proxyAdmin);
        freshToken.initializeV6();
        assertEq(freshToken.owner(), expectedOwner, "Owner unchanged after V6");
        // _initialized must now be 6.
        assertEq(uint256(vm.load(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT)) & 0xff, 6, "_initialized should be 6");
    }

    function test_sepoliaUpgradePath_V6only() public {
        // Sepolia-like pre-2026-07-06 path: already at _initialized = 5, only V6 needed.
        (FabricaToken freshToken, address freshProxyAddr) = _freshToken(proxyAdmin);
        // Simulate Sepolia state: owner already in ERC-7201 slot, _initialized = 5.
        address expectedOwner = makeAddr("expectedOwner");
        vm.store(freshProxyAddr, OZ_V5_OWNER_SLOT, bytes32(uint256(uint160(expectedOwner))));
        vm.store(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT, bytes32(uint256(5)));
        // Deploy new implementation and upgrade with V6 only.
        FabricaToken newImpl = new FabricaToken();
        vm.prank(proxyAdmin);
        freshToken.upgradeToAndCall(address(newImpl), abi.encodeCall(FabricaToken.initializeV6, ()));
        assertEq(freshToken.owner(), expectedOwner, "Owner should remain set after V6-only upgrade");
        assertEq(freshToken.implementation(), address(newImpl), "Implementation should be updated");
        assertEq(uint256(vm.load(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT)) & 0xff, 6, "_initialized should be 6");
    }

    function test_runNoInit_emptyDataUpgradePreservesV6State() public {
        (FabricaToken freshToken, address freshProxyAddr) = _freshToken(proxyAdmin);
        vm.prank(proxyAdmin);
        freshToken.initializeV6();
        address ownerBefore = freshToken.owner();
        uint256 versionBefore = uint256(vm.load(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT)) & 0xff;
        FabricaToken newImpl = new FabricaToken();
        vm.prank(proxyAdmin);
        freshToken.upgradeToAndCall(address(newImpl), "");
        assertEq(freshToken.implementation(), address(newImpl), "empty-data upgrade should set impl");
        assertEq(freshToken.owner(), ownerBefore, "empty-data upgrade should preserve owner");
        assertEq(uint256(vm.load(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT)) & 0xff, versionBefore, "version unchanged");
    }

    function test_run_scriptHelper_v6RequiresV5State() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (FabricaToken freshToken, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        vm.store(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT, bytes32(uint256(5)));
        FabricaToken newImpl = new FabricaToken();
        _setUpgradeScriptContext(script, freshProxyAddr, address(newImpl));
        script.run(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
        assertEq(freshToken.implementation(), address(newImpl), "script run should set impl");
        assertEq(uint256(vm.load(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT)) & 0xff, 6, "version bumped");
    }

    function test_run_scriptHelper_revertsBeforeV5() public {
        _expectTwoAddressScriptRevert(false);
    }

    function test_runWithV4_scriptHelper_ownerMigrationRequiresFreshV5InitializerSlot() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        address expectedOwner = makeAddr("expectedOwner");
        (FabricaToken freshToken, address freshProxyAddr) =
            _freshTokenWithLegacyOwner(FORGE_DEFAULT_BROADCASTER, expectedOwner);
        vm.store(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT, bytes32(0));
        FabricaToken newImpl = new FabricaToken();
        _setUpgradeScriptContext(script, freshProxyAddr, address(newImpl));
        script.runWithV4(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
        assertEq(freshToken.implementation(), address(newImpl), "script runWithV4 should set impl");
        assertEq(freshToken.owner(), expectedOwner, "script runWithV4 should migrate owner");
        assertEq(uint256(vm.load(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT)) & 0xff, 4, "version bumped");
    }

    function test_runWithV4_scriptHelper_revertsAfterV4Initialized() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        address expectedOwner = makeAddr("expectedOwner");
        (, address freshProxyAddr) = _freshTokenWithLegacyOwner(FORGE_DEFAULT_BROADCASTER, expectedOwner);
        vm.store(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT, bytes32(uint256(4)));
        FabricaToken newImpl = new FabricaToken();
        _setUpgradeScriptContext(script, freshProxyAddr, address(newImpl));
        vm.expectRevert("unexpected initialized version");
        script.runWithV4(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
    }

    function test_runNoInit_scriptHelper_emptyDataUpgradePreservesV6State() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (FabricaToken freshToken, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        vm.prank(FORGE_DEFAULT_BROADCASTER);
        freshToken.initializeV6();
        uint256 versionBefore = uint256(vm.load(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT)) & 0xff;
        FabricaToken newImpl = new FabricaToken();
        _setUpgradeScriptContext(script, freshProxyAddr, address(newImpl));
        script.runNoInit(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
        assertEq(freshToken.implementation(), address(newImpl), "script runNoInit should set impl");
        assertEq(uint256(vm.load(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT)) & 0xff, versionBefore, "version unchanged");
    }

    function test_runNoInit_scriptHelper_revertsWhenFullInitializedVersionDiffers() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        vm.store(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT, bytes32(uint256(262)));
        FabricaToken newImpl = new FabricaToken();
        _setUpgradeScriptContext(script, freshProxyAddr, address(newImpl));
        vm.expectRevert("unexpected initialized version");
        script.runNoInit(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
    }

    function test_runNoInit_scriptHelper_revertsWhenExpectedImplementationDiffers() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        FabricaToken newImpl = new FabricaToken();
        _setUpgradeScriptContext(script, freshProxyAddr, makeAddr("wrongExpectedImpl"));
        vm.expectRevert("unexpected token implementation");
        script.runNoInit(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
    }

    function test_runNoInit_scriptHelper_revertsWhenExpectedCurrentImplementationDiffers() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        FabricaToken newImpl = new FabricaToken();
        _setUpgradeScriptContext(script, freshProxyAddr, address(newImpl), makeAddr("wrongCurrentImpl"));
        vm.expectRevert("unexpected current implementation");
        script.runNoInit(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
    }

    function test_runNoInit_scriptHelper_revertsBeforeV6() public {
        _expectTwoAddressScriptRevert(true);
    }

    function test_runNoInit_scriptHelper_revertsWhenProxyAndImplementationAreSwapped() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (FabricaToken freshToken, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        vm.prank(FORGE_DEFAULT_BROADCASTER);
        freshToken.initializeV6();
        FabricaToken newImpl = new FabricaToken();
        _setUpgradeScriptContext(script, freshProxyAddr, address(newImpl));
        vm.expectRevert("unexpected token proxy");
        script.runNoInit(_tokenProxy(address(newImpl)), _tokenImplementation(freshProxyAddr));
    }

    function test_runNoInit_scriptHelper_revertsOnInvalidUpgradeTargets() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        FabricaToken newImpl = new FabricaToken();
        _expectRunNoInitTargetRevert(script, address(0), address(newImpl), "token proxy zero");
        _expectRunNoInitTargetRevert(script, freshProxyAddr, address(0), "new implementation zero");
        _expectRunNoInitTargetRevert(script, freshProxyAddr, freshProxyAddr, "proxy and implementation match");
        _expectRunNoInitTargetRevert(script, freshProxyAddr, makeAddr("notImpl"), "new implementation has no code");
    }

    function test_runNoInit_scriptHelper_revertsWhenCurrentImplementationHasNoCode() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        vm.store(freshProxyAddr, ERC1967_IMPLEMENTATION_SLOT, bytes32(uint256(uint160(makeAddr("goneImpl")))));
        FabricaToken newImpl = new FabricaToken();
        _setUpgradeScriptContext(script, freshProxyAddr, address(newImpl), makeAddr("goneImpl"));
        vm.expectRevert("current implementation has no code");
        script.runNoInit(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
    }

    function test_runNoInit_scriptHelper_revertsOnWrongImplementationType() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (FabricaToken freshToken, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        vm.prank(FORGE_DEFAULT_BROADCASTER);
        freshToken.initializeV6();
        FabricaFeeCollector wrongImpl = new FabricaFeeCollector();
        _setUpgradeScriptContext(script, freshProxyAddr, address(wrongImpl));
        vm.expectRevert("new implementation is not FabricaToken");
        script.runNoInit(_tokenProxy(freshProxyAddr), _tokenImplementation(address(wrongImpl)));
    }

    function test_runNoInit_scriptHelper_revertsWhenImplementationMissingRegistryProbe() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (FabricaToken freshToken, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        vm.prank(FORGE_DEFAULT_BROADCASTER);
        freshToken.initializeV6();
        MockDefaultValidatorOnly wrongImpl = new MockDefaultValidatorOnly();
        _setUpgradeScriptContext(script, freshProxyAddr, address(wrongImpl));
        vm.expectRevert("new implementation is not FabricaToken");
        script.runNoInit(_tokenProxy(freshProxyAddr), _tokenImplementation(address(wrongImpl)));
    }

    function test_runV5Only_scriptHelper_succeedsAfterV4() public {
        _assertInitializerScriptSuccess(false);
    }

    function test_runV5Only_scriptHelper_revertsBeforeV4() public {
        _assertInitializerScriptVersionRevert(false);
    }

    function test_runV5Only_scriptHelper_preservesInitializerRevertData() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (, address freshProxyAddr) = _freshToken(proxyAdmin);
        vm.store(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT, bytes32(uint256(4)));
        _setInitializerScriptContext(script, freshProxyAddr);
        vm.expectRevert("FabricaUUPSUpgradeable: caller is not the proxy admin");
        script.runV5Only(freshProxyAddr);
    }

    function test_runV5Only_scriptHelper_revertsWhenProxyHasNoCode() public {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        address notProxy = makeAddr("notProxy");
        _setInitializerScriptContext(script, notProxy, address(0));
        vm.expectRevert("token proxy has no code");
        script.runV5Only(notProxy);
    }

    function test_runV6Only_scriptHelper_succeedsAfterV5() public {
        _assertInitializerScriptSuccess(true);
    }

    function test_runV6Only_scriptHelper_revertsBeforeV5() public {
        _assertInitializerScriptVersionRevert(true);
    }

    function _freshToken(address admin) internal returns (FabricaToken freshToken, address freshProxyAddr) {
        FabricaToken impl = new FabricaToken();
        FabricaProxy freshProxy = new FabricaProxy(address(impl), admin, abi.encodeCall(FabricaToken.initialize, ()));
        freshProxyAddr = address(freshProxy);
        freshToken = FabricaToken(freshProxyAddr);
    }

    function _expectTwoAddressScriptRevert(bool noInit) internal {
        (, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        FabricaToken newImpl = new FabricaToken();
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        _setUpgradeScriptContext(script, freshProxyAddr, address(newImpl));
        vm.expectRevert("unexpected initialized version");
        if (noInit) {
            script.runNoInit(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
        } else {
            script.run(_tokenProxy(freshProxyAddr), _tokenImplementation(address(newImpl)));
        }
    }

    function _expectRunNoInitTargetRevert(
        FabricaTokenUpgradeScript script,
        address tokenProxy,
        address newImplementation,
        string memory reason
    ) internal {
        _setUpgradeScriptContext(script, tokenProxy, newImplementation);
        vm.expectRevert(bytes(reason));
        script.runNoInit(_tokenProxy(tokenProxy), _tokenImplementation(newImplementation));
    }

    function _tokenProxy(address tokenProxy) internal pure returns (TokenProxy) {
        return TokenProxy.wrap(tokenProxy);
    }

    function _tokenImplementation(address tokenImplementation) internal pure returns (TokenImplementation) {
        return TokenImplementation.wrap(tokenImplementation);
    }

    function _setUpgradeScriptContext(FabricaTokenUpgradeScript script, address tokenProxy, address newImplementation)
        internal
    {
        _setUpgradeScriptContext(script, tokenProxy, newImplementation, _currentImplementationOrZero(tokenProxy));
    }

    function _setUpgradeScriptContext(
        FabricaTokenUpgradeScript script,
        address tokenProxy,
        address newImplementation,
        address expectedCurrentImplementation
    ) internal {
        script.configureExpectedUpgradeContext(
            FabricaTokenUpgradeScript.ExpectedUpgradeContextInput({
                chainId: block.chainid,
                tokenProxy: tokenProxy,
                tokenImplementation: newImplementation,
                currentImplementation: expectedCurrentImplementation
            })
        );
    }

    function _setInitializerScriptContext(FabricaTokenUpgradeScript script, address tokenProxy) internal {
        _setInitializerScriptContext(script, tokenProxy, _currentImplementationOrZero(tokenProxy));
    }

    function _setInitializerScriptContext(
        FabricaTokenUpgradeScript script,
        address tokenProxy,
        address expectedCurrentImplementation
    ) internal {
        script.configureExpectedInitializerContext(
            FabricaTokenUpgradeScript.ExpectedInitializerContextInput({
                chainId: block.chainid, tokenProxy: tokenProxy, currentImplementation: expectedCurrentImplementation
            })
        );
    }

    function _currentImplementationOrZero(address tokenProxy) internal view returns (address) {
        if (tokenProxy.code.length == 0) return address(0);
        (bool ok, bytes memory implementationReturnData) =
            tokenProxy.staticcall(abi.encodeWithSignature("implementation()"));
        if (!ok || implementationReturnData.length < 32) return address(0);
        return abi.decode(implementationReturnData, (address));
    }

    function _assertInitializerCannotBeCalledTwice(bool v6) internal {
        (FabricaToken freshToken,) = _freshToken(proxyAdmin);
        vm.prank(proxyAdmin);
        if (v6) {
            freshToken.initializeV6();
        } else {
            freshToken.initializeV5();
        }
        vm.prank(proxyAdmin);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        if (v6) {
            freshToken.initializeV6();
        } else {
            freshToken.initializeV5();
        }
    }

    function _assertInitializerScriptSuccess(bool v6) internal {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        vm.store(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT, bytes32(uint256(v6 ? 5 : 4)));
        _setInitializerScriptContext(script, freshProxyAddr);
        if (v6) {
            script.runV6Only(freshProxyAddr);
        } else {
            script.runV5Only(freshProxyAddr);
        }
        assertEq(uint256(vm.load(freshProxyAddr, OZ_V5_INITIALIZABLE_SLOT)) & 0xff, v6 ? 6 : 5, "version bumped");
    }

    function _assertInitializerScriptVersionRevert(bool v6) internal {
        FabricaTokenUpgradeScript script = new FabricaTokenUpgradeScript();
        (, address freshProxyAddr) = _freshToken(FORGE_DEFAULT_BROADCASTER);
        _setInitializerScriptContext(script, freshProxyAddr);
        vm.expectRevert("unexpected initialized version");
        if (v6) {
            script.runV6Only(freshProxyAddr);
        } else {
            script.runV5Only(freshProxyAddr);
        }
    }

    function _freshTokenWithLegacyOwner(address expectedOwner)
        internal
        returns (FabricaToken freshToken, address freshProxyAddr)
    {
        return _freshTokenWithLegacyOwner(proxyAdmin, expectedOwner);
    }

    function _freshTokenWithLegacyOwner(address admin, address expectedOwner)
        internal
        returns (FabricaToken freshToken, address freshProxyAddr)
    {
        (freshToken, freshProxyAddr) = _freshToken(admin);
        vm.store(freshProxyAddr, bytes32(uint256(101)), bytes32(uint256(uint160(expectedOwner))));
        vm.store(freshProxyAddr, OZ_V5_OWNER_SLOT, bytes32(0));
    }

    function test_allSlots_endToEnd() public {
        // This test verifies that after the gap fix, all 6 state variables
        // are functional and reading from the correct storage positions.
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address operator = makeAddr("operator");
        // 1. Mint tokens (tests _balances at 301, _property at 303, _defaultValidator at 304)
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 700;
        amounts[1] = 300;
        vm.prank(user1);
        uint256 tokenId = token.mint(recipients, 3, amounts, "test-definition", "", "", address(0));
        assertEq(token.balanceOf(user1, tokenId), 700, "user1 balance should be 700");
        assertEq(token.balanceOf(user2, tokenId), 300, "user2 balance should be 300");
        // 2. Set approval (tests _operatorApprovals at 302)
        vm.prank(user1);
        token.setApprovalForAll(operator, true);
        assertTrue(token.isApprovedForAll(user1, operator), "operator should be approved");
        // 3. Transfer tokens (tests _balances reads AND writes)
        vm.prank(operator);
        token.safeTransferFrom(user1, user2, tokenId, 100, "");
        assertEq(token.balanceOf(user1, tokenId), 600, "user1 balance after transfer");
        assertEq(token.balanceOf(user2, tokenId), 400, "user2 balance after transfer");
        // 4. Verify _defaultValidator (slot 304)
        assertEq(token.defaultValidator(), address(validator), "defaultValidator should be set");
        // 5. Verify _validatorRegistry (slot 305)
        assertEq(token.validatorRegistry(), address(registry), "validatorRegistry should be set");
        // 6. Verify _contractURI (slot 306)
        assertEq(token.contractURI(), "https://example.com/contract-uri", "contractURI should be set");
        // 7. Verify _property (slot 303) — check supply via public getter
        (uint256 supply,,,,) = token._property(tokenId);
        assertEq(supply, 1000, "property supply should be 1000");
    }
}
