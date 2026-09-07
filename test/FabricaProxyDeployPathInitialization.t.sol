// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {FabricaFeeCollectorScript} from "../script/FabricaFeeCollector.s.sol";
import {FabricaGuardedSignedPriceOracleDeployScript} from "../script/FabricaGuardedSignedPriceOracleDeploy.s.sol";
import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";
import {FabricaGuardedSignedPriceOracle} from "../src/FabricaGuardedSignedPriceOracle.sol";

/// @notice ENG-3966 — pins atomic proxy initialization on the REAL deploy-script paths.
/// @dev Answers evmbench job `a67c726d-4c4c-418c-aad1-6e857a5e1f07` (contracts#44 round 4), which
///      reported two `high` findings:
///        - finding 0: "Uninitialized fee collector proxy can be taken over to drain users via
///          existing ERC-20 allowances" (`FabricaFeeCollector.sol`, `FabricaProxy.sol`)
///        - finding 1: "Uninitialized signed price oracle proxy can be taken over to return
///          attacker-controlled prices" (`FabricaGuardedSignedPriceOracle.sol`, `FabricaProxy.sol`)
///      Both are conditional on a proxy being deployed with EMPTY `_data`, leaving a window in
///      which anyone may call `initialize`. That precondition was checked by reading the source
///      during ENG-3924 triage but was never pinned by a test, so a repeat scan had no durable
///      answer. This file is that answer: it drives the production deploy scripts themselves —
///      not a hand-rolled copy of their bodies — and asserts the proxy comes out of the deploy
///      already initialized and un-re-initializable, and that the implementation behind it is
///      locked by `_disableInitializers()`.
///      Live-chain readback evidence for the deployed proxies is recorded in
///      `deployment-artifacts/ENG-3966-guarded-price-oracle-sepolia.md`.
contract FabricaProxyDeployPathInitializationTest is Test {
    /// @dev `Initialized(uint64)` from OpenZeppelin `Initializable`.
    bytes32 private constant INITIALIZED_TOPIC = keccak256("Initialized(uint64)");
    /// @dev `Upgraded(address)` from ERC-1967.
    bytes32 private constant UPGRADED_TOPIC = keccak256("Upgraded(address)");
    /// @dev EIP-1967 implementation slot.
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev OpenZeppelin v5 `InitializableStorage` namespaced slot.
    bytes32 private constant INITIALIZABLE_STORAGE = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    string private constant ORACLE_NAME = "Fabrica Guarded Signed Price Oracle";

    address private constant STRANGER = address(0xBADBAD);
    address private constant ORACLE_OWNER = address(0x0A511E);
    address private constant FEE_OWNER = address(0xFEE0E1);
    address private constant FEE_PROXY_ADMIN = address(0xAD);
    address private constant FEE_PROTOCOL_CONTRACT = address(0xC0117AC7);
    address private constant FEE_RECIPIENT = address(0xFEE);
    uint8 private constant FEE_SHARE_PERCENT = 10;

    FabricaGuardedSignedPriceOracleDeployScript private oracleScript;
    FabricaFeeCollectorScript private feeScript;

    function setUp() public {
        oracleScript = new FabricaGuardedSignedPriceOracleDeployScript();
        feeScript = new FabricaFeeCollectorScript();
    }

    // ---------------------------------------------------------------------
    // FabricaGuardedSignedPriceOracle — script/FabricaGuardedSignedPriceOracleDeploy.s.sol
    // ---------------------------------------------------------------------

    /// @notice The oracle deploy script initializes the proxy inside the deployment itself.
    function test_oracleDeployScriptInitializesProxyAtomically() public {
        (FabricaGuardedSignedPriceOracle oracle, Vm.Log[] memory logs) = _runOracleScriptWithLogs();
        assertEq(oracle.owner(), ORACLE_OWNER, "oracle owner must be set by the deploy-time initialize");
        assertEq(_initializedVersion(address(oracle)), 1, "oracle proxy must be at initialized version 1");
        assertTrue(_implementationOf(address(oracle)) != address(0), "oracle proxy must have an implementation");
        assertTrue(
            _sawTopicFrom(logs, INITIALIZED_TOPIC, address(oracle)),
            "oracle proxy must emit Initialized during the deploy"
        );
        assertTrue(
            _sawTopicFrom(logs, UPGRADED_TOPIC, address(oracle)), "oracle proxy must emit Upgraded during the deploy"
        );
    }

    /// @notice A stranger cannot re-initialize the oracle proxy the deploy script produced.
    function test_oracleDeployScriptProxyRejectsStrangerReinitialization() public {
        FabricaGuardedSignedPriceOracle oracle = _runOracleScript();
        vm.prank(STRANGER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(STRANGER, "takeover");
        assertEq(oracle.owner(), ORACLE_OWNER, "oracle owner must survive the attempted takeover");
    }

    /// @notice The oracle implementation behind the deployed proxy is locked.
    function test_oracleDeployScriptImplementationIsLocked() public {
        FabricaGuardedSignedPriceOracle oracle = _runOracleScript();
        address implementation = _implementationOf(address(oracle));
        assertEq(
            _initializedVersion(implementation),
            type(uint64).max,
            "oracle implementation must be locked by _disableInitializers()"
        );
        vm.prank(STRANGER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        FabricaGuardedSignedPriceOracle(implementation).initialize(STRANGER, "takeover");
    }

    // ---------------------------------------------------------------------
    // FabricaFeeCollector — script/FabricaFeeCollector.s.sol
    // ---------------------------------------------------------------------

    /// @notice The fee-collector deploy script initializes the proxy inside the deployment itself,
    ///         and the script's `transferOwnership` leg lands the intended owner.
    function test_feeCollectorDeployScriptInitializesProxyAtomically() public {
        (FabricaFeeCollector collector, Vm.Log[] memory logs) = _runFeeCollectorScriptWithLogs();
        assertEq(collector.owner(), FEE_OWNER, "fee collector owner must be the owner the script transfers to");
        assertEq(collector.protocolContractAddress(), FEE_PROTOCOL_CONTRACT, "protocol contract must be initialized");
        assertEq(collector.protocolFeeRecipient(), FEE_RECIPIENT, "fee recipient must be initialized");
        assertEq(collector.protocolSharePercent(), FEE_SHARE_PERCENT, "share percent must be initialized");
        assertEq(collector.proxyAdmin(), FEE_PROXY_ADMIN, "proxy admin must be the admin the script passes");
        assertEq(_initializedVersion(address(collector)), 1, "fee collector proxy must be at initialized version 1");
        assertTrue(
            _sawTopicFrom(logs, INITIALIZED_TOPIC, address(collector)),
            "fee collector proxy must emit Initialized during the deploy"
        );
        assertTrue(
            _sawTopicFrom(logs, UPGRADED_TOPIC, address(collector)),
            "fee collector proxy must emit Upgraded during the deploy"
        );
    }

    /// @notice A stranger cannot re-initialize the fee-collector proxy the deploy script produced.
    function test_feeCollectorDeployScriptProxyRejectsStrangerReinitialization() public {
        FabricaFeeCollector collector = _runFeeCollectorScript();
        vm.prank(STRANGER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        collector.initialize(STRANGER, 100, STRANGER);
        assertEq(collector.owner(), FEE_OWNER, "fee collector owner must survive the attempted takeover");
    }

    /// @notice The fee-collector implementation behind the deployed proxy is locked.
    function test_feeCollectorDeployScriptImplementationIsLocked() public {
        FabricaFeeCollector collector = _runFeeCollectorScript();
        address implementation = _implementationOf(address(collector));
        assertEq(
            _initializedVersion(implementation),
            type(uint64).max,
            "fee collector implementation must be locked by _disableInitializers()"
        );
        vm.prank(STRANGER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        FabricaFeeCollector(implementation).initialize(STRANGER, 100, STRANGER);
    }

    // ---------------------------------------------------------------------
    // evmbench finding-0 / finding-1 precondition, pinned
    // ---------------------------------------------------------------------

    /// @notice Pins the precondition both evmbench findings depend on: NEITHER production deploy
    ///         path leaves a proxy uninitialized, so neither takeover is reachable.
    /// @dev evmbench job `a67c726d-4c4c-418c-aad1-6e857a5e1f07`, contracts#44 round 4, findings 0
    ///      and 1. The findings require a proxy constructed with empty `_data`. Running the real
    ///      scripts and reading the proxies' `InitializableStorage` proves the opposite: both come
    ///      out at initialized version 1 with a non-zero owner, in the deploying call itself.
    ///      Whoever changes a deploy script to drop its init data fails HERE, with this citation.
    function test_evmbenchFinding0And1Precondition_deployPathsNeverLeaveAProxyUninitialized() public {
        FabricaGuardedSignedPriceOracle oracle = _runOracleScript();
        FabricaFeeCollector collector = _runFeeCollectorScript();
        assertEq(_initializedVersion(address(oracle)), 1, "oracle deploy path must not leave the proxy uninitialized");
        assertEq(
            _initializedVersion(address(collector)),
            1,
            "fee collector deploy path must not leave the proxy uninitialized"
        );
        assertTrue(oracle.owner() != address(0), "an uninitialized oracle proxy would report a zero owner");
        assertTrue(collector.owner() != address(0), "an uninitialized fee collector proxy would report a zero owner");
    }

    /// @notice Pins the other half of the precondition: both implementations disable initializers
    ///         in their constructors, so a bare implementation cannot be initialized either.
    /// @dev Same evmbench job `a67c726d-4c4c-418c-aad1-6e857a5e1f07`, contracts#44 round 4.
    ///      `src/FabricaGuardedSignedPriceOracle.sol` and `src/FabricaFeeCollector.sol` both call
    ///      `_disableInitializers()` in their constructors; this asserts the resulting on-chain
    ///      state rather than the presence of the source line.
    function test_evmbenchFinding0And1Precondition_freshImplementationsDisableInitializers() public {
        FabricaGuardedSignedPriceOracle oracleImplementation = new FabricaGuardedSignedPriceOracle();
        FabricaFeeCollector feeImplementation = new FabricaFeeCollector();
        assertEq(
            _initializedVersion(address(oracleImplementation)),
            type(uint64).max,
            "oracle implementation constructor must call _disableInitializers()"
        );
        assertEq(
            _initializedVersion(address(feeImplementation)),
            type(uint64).max,
            "fee collector implementation constructor must call _disableInitializers()"
        );
        vm.prank(STRANGER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracleImplementation.initialize(STRANGER, "takeover");
        vm.prank(STRANGER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        feeImplementation.initialize(STRANGER, 100, STRANGER);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Drives the production oracle deploy script exactly as an operator would.
    function _runOracleScript() private returns (FabricaGuardedSignedPriceOracle oracle) {
        (oracle,) = _runOracleScriptWithLogs();
    }

    /// @dev As `_runOracleScript`, also returning the logs the deployment emitted. Log recording
    ///      lives here rather than in the tests because `vm.getRecordedLogs` drains the buffer, so
    ///      a caller that started its own recording would be left with nothing.
    function _runOracleScriptWithLogs() private returns (FabricaGuardedSignedPriceOracle oracle, Vm.Log[] memory logs) {
        vm.setEnv("GUARDED_ORACLE_OWNER", vm.toString(ORACLE_OWNER));
        vm.setEnv("GUARDED_ORACLE_NAME", ORACLE_NAME);
        vm.recordLogs();
        oracle = oracleScript.run();
        logs = vm.getRecordedLogs();
    }

    /// @dev Drives the production fee-collector deploy script exactly as an operator would.
    function _runFeeCollectorScript() private returns (FabricaFeeCollector collector) {
        (collector,) = _runFeeCollectorScriptWithLogs();
    }

    /// @dev As `_runFeeCollectorScript`, also returning the logs the deployment emitted. The script
    ///      logs the proxy rather than returning it, so the proxy is recovered from the ERC-1967
    ///      `Upgraded` event the deployment emits.
    function _runFeeCollectorScriptWithLogs() private returns (FabricaFeeCollector collector, Vm.Log[] memory logs) {
        vm.recordLogs();
        feeScript.run(FEE_PROTOCOL_CONTRACT, FEE_SHARE_PERCENT, FEE_RECIPIENT, FEE_PROXY_ADMIN, FEE_OWNER);
        logs = vm.getRecordedLogs();
        collector = FabricaFeeCollector(_onlyEmitterOf(logs, UPGRADED_TOPIC));
    }

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

    /// @dev Low 64 bits of OpenZeppelin v5 `InitializableStorage._initialized`.
    function _initializedVersion(address target) private view returns (uint64) {
        return uint64(uint256(vm.load(target, INITIALIZABLE_STORAGE)));
    }

    function _sawTopicFrom(Vm.Log[] memory logs, bytes32 topic, address emitter) private pure returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == emitter && logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                return true;
            }
        }
        return false;
    }

    /// @dev Returns the single emitter of `topic`, reverting if the count is not exactly one so a
    ///      changed deploy sequence surfaces as a failure rather than an arbitrary pick.
    function _onlyEmitterOf(Vm.Log[] memory logs, bytes32 topic) private pure returns (address emitter) {
        uint256 seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == topic) {
                emitter = logs[i].emitter;
                seen++;
            }
        }
        require(seen == 1, "expected exactly one Upgraded emitter in the deploy");
    }
}
