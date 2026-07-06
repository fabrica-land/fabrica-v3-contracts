// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";
import {MockERC20ReturnsFalse} from "./FabricaFeeCollector.t.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

// Fork-based verification of the ENG-2547/ENG-2548 upgrade against the REAL
// deployed proxies. For each proxy this test: reproduces the vulnerability on
// the currently-deployed implementation, upgrades the proxy in-fork to a
// freshly-compiled implementation, asserts persistent state is not regressed,
// and asserts both audit fixes are now live. The mainnet cases double as the
// spec-only Safe/EOA upgrade simulation required by the shipping playbook.
contract FabricaFeeCollectorForkUpgradeTest is ForkTestBase {
    address internal constant OBLIGOR = address(0x0B119012);

    struct CollectorState {
        address admin;
        address ownerAddr;
        address originalImpl;
        uint8 originalShare;
        address originalProtocolContract;
        address originalRecipient;
        bool originalPaused;
    }

    struct ForkPreset {
        string rpcEnvVar;
        string rpcAlias;
        uint256 blockNumber;
    }

    address internal constant MAINNET_PROD = 0x4432CFaF8BD8d55A07D938BbC43c91DDa7672bD4;
    address internal constant MAINNET_DEVELOP = 0xF9Aa471711560F64b0813Ad46392d4D66532c74B;
    address internal constant MAINNET_STAGING = 0xD983F633B0aaE06F52C0C48cd35967f097dC2B5C;

    // Pinned fork blocks. These require an ARCHIVE RPC — they are far deeper
    // than a pruned node's window (both proxies were deployed 2025-07). They
    // MUST stay BELOW the block at which the real on-chain upgrade ships: the
    // pre-fix vuln repro below (setProtocolSharePercent(200) accepted) only
    // holds while each proxy still runs its OLD implementation at this block.
    uint256 internal constant SEPOLIA_BLOCK = 11187000;
    uint256 internal constant MAINNET_BLOCK = 25445000;

    // Full before/after upgrade verification for one live proxy.
    function _verifyUpgrade(address proxyAddr) internal {
        FabricaFeeCollector proxy = FabricaFeeCollector(proxyAddr);
        CollectorState memory state = _captureState(proxyAddr, proxy);
        _reproduceShareBoundVulnerability(proxy, state);
        FabricaFeeCollector newImpl = new FabricaFeeCollector();
        vm.prank(state.admin);
        proxy.upgradeToAndCall(address(newImpl), "");
        assertEq(proxy.implementation(), address(newImpl), "impl not updated");
        _assertStatePreserved(proxy, state);
        _assertAuditFixes(proxyAddr, proxy, state.ownerAddr);
    }

    function _captureState(address proxyAddr, FabricaFeeCollector proxy)
        internal
        returns (CollectorState memory state)
    {
        state = CollectorState({
            admin: proxy.proxyAdmin(),
            ownerAddr: proxy.owner(),
            originalImpl: proxy.implementation(),
            originalShare: proxy.protocolSharePercent(),
            originalProtocolContract: proxy.protocolContractAddress(),
            originalRecipient: proxy.protocolFeeRecipient(),
            originalPaused: proxy.paused()
        });
        emit log_named_address("proxy", proxyAddr);
        emit log_named_address("proxyAdmin", state.admin);
        emit log_named_address("owner", state.ownerAddr);
        emit log_named_address("original impl", state.originalImpl);
        emit log_named_uint("original protocolSharePercent", state.originalShare);
    }

    function _reproduceShareBoundVulnerability(FabricaFeeCollector proxy, CollectorState memory state) internal {
        // Reproduce ENG-2548 on the CURRENT impl: an out-of-range share is
        // accepted (no bound). Proves the fix is not yet live on-chain.
        vm.prank(state.ownerAddr);
        proxy.setProtocolSharePercent(200);
        assertEq(proxy.protocolSharePercent(), 200, "pre-fix impl should accept >100 (vuln repro)");
        vm.prank(state.ownerAddr);
        proxy.setProtocolSharePercent(state.originalShare);
    }

    function _assertStatePreserved(FabricaFeeCollector proxy, CollectorState memory state) internal view {
        // No-regression: persistent business state is preserved across the upgrade.
        assertEq(proxy.owner(), state.ownerAddr, "owner regressed");
        assertEq(proxy.protocolSharePercent(), state.originalShare, "share regressed");
        assertEq(proxy.protocolContractAddress(), state.originalProtocolContract, "protocolContract regressed");
        assertEq(proxy.protocolFeeRecipient(), state.originalRecipient, "recipient regressed");
        assertEq(proxy.paused(), state.originalPaused, "paused regressed");
    }

    function _assertAuditFixes(address proxyAddr, FabricaFeeCollector proxy, address ownerAddr) internal {
        // ENG-2548 fix is now live: the bound reverts with the custom error.
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSelector(FabricaFeeCollector.ProtocolSharePercentExceedsMaximum.selector, 101));
        proxy.setProtocolSharePercent(101);
        // ENG-2547 fix is now live: a returns-false token makes collectFee
        // revert via SafeERC20 instead of silently succeeding.
        MockERC20ReturnsFalse token = new MockERC20ReturnsFalse();
        token.mint(OBLIGOR, 1_000);
        vm.prank(OBLIGOR);
        token.approve(proxyAddr, 1_000);
        // collectFee is whenNotPaused; unpause on the fork only if needed so the
        // SafeERC20 assertion is what actually trips.
        if (proxy.paused()) {
            vm.prank(ownerAddr);
            (bool ok,) = proxyAddr.call(abi.encodeWithSignature("unpause()"));
            assertTrue(ok, "unpause failed on fork");
        }
        vm.prank(ownerAddr);
        vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(token)));
        proxy.collectFee(1, "onramp", OBLIGOR, address(token), 1_000);
    }

    function _verifyForkUpgrade(ForkConfig memory config, address proxyAddr) internal {
        if (!_forkOrSkip(config)) return;
        _verifyUpgrade(proxyAddr);
    }

    function _sepoliaFork() internal pure returns (ForkConfig memory) {
        return _forkConfig(ForkPreset({rpcEnvVar: "SEPOLIA_RPC_URL", rpcAlias: "sepolia", blockNumber: SEPOLIA_BLOCK}));
    }

    function _mainnetFork() internal pure returns (ForkConfig memory) {
        return _forkConfig(ForkPreset({rpcEnvVar: "MAINNET_RPC_URL", rpcAlias: "mainnet", blockNumber: MAINNET_BLOCK}));
    }

    function _forkConfig(ForkPreset memory preset) internal pure returns (ForkConfig memory) {
        return ForkConfig({
            rpcEnvVar: preset.rpcEnvVar, rpcAlias: preset.rpcAlias, blockNumber: preset.blockNumber, requiredEnvVar: ""
        });
    }

    function test_fork_sepolia_prod() public {
        _verifyForkUpgrade(_sepoliaFork(), SEPOLIA_FEE_PROXY_PROD);
    }

    function test_fork_sepolia_staging() public {
        _verifyForkUpgrade(_sepoliaFork(), SEPOLIA_FEE_PROXY_STAGING);
    }

    function test_fork_sepolia_develop() public {
        _verifyForkUpgrade(_sepoliaFork(), SEPOLIA_FEE_PROXY_DEVELOP);
    }

    function test_fork_mainnet_prod() public {
        _verifyForkUpgrade(_mainnetFork(), MAINNET_PROD);
    }

    function test_fork_mainnet_develop() public {
        _verifyForkUpgrade(_mainnetFork(), MAINNET_DEVELOP);
    }

    function test_fork_mainnet_staging() public {
        _verifyForkUpgrade(_mainnetFork(), MAINNET_STAGING);
    }
}
