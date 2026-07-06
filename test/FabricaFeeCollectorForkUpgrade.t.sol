// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";
import {ForkTestBase} from "./ForkTestBase.sol";

// Minimal view/mutation surface of the deployed FabricaFeeCollector proxies,
// enough to read state, upgrade, and exercise both audit fixes on a fork.
interface IFeeCollectorProxy {
    function implementation() external view returns (address);
    function proxyAdmin() external view returns (address);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function protocolSharePercent() external view returns (uint8);
    function protocolContractAddress() external view returns (address);
    function protocolFeeRecipient() external view returns (address);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function setProtocolSharePercent(uint8 newProtocolSharePercent) external;
    function collectFee(
        uint256 tokenId,
        string calldata feeType,
        address obligor,
        address erc20CurrencyAddress,
        uint256 amount
    ) external;
}

// A token whose transferFrom returns `false` without reverting (legacy-BNB
// style). The pre-fix collector used a raw transfer and would silently treat
// this as success; the SafeERC20 fix must make collectFee revert.
contract MockERC20ReturnsFalse {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

// Fork-based verification of the ENG-2547/ENG-2548 upgrade against the REAL
// deployed proxies. For each proxy this test: reproduces the vulnerability on
// the currently-deployed implementation, upgrades the proxy in-fork to a
// freshly-compiled implementation, asserts persistent state is not regressed,
// and asserts both audit fixes are now live. The mainnet cases double as the
// spec-only Safe/EOA upgrade simulation required by the shipping playbook.
contract FabricaFeeCollectorForkUpgradeTest is ForkTestBase {
    address internal constant OBLIGOR = address(0x0B119012);

    // ENG-2547/2548 verified on-chain proxy addresses (see ticket topology comment).
    address internal constant SEPOLIA_PROD = 0x404f53869aD67e167a8C89035f55572e653d7B22;
    address internal constant SEPOLIA_STAGING = 0x98e819BF78081f4343E71Ed4096C59d74948C166;
    address internal constant SEPOLIA_DEVELOP = 0x24888646723ae14C83E5354431753675A3d12D3c;
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
        IFeeCollectorProxy proxy = IFeeCollectorProxy(proxyAddr);
        address admin = proxy.proxyAdmin();
        address ownerAddr = proxy.owner();
        // Capture persistent state to prove the upgrade does not regress storage.
        address originalImpl = proxy.implementation();
        uint8 originalShare = proxy.protocolSharePercent();
        address originalProtocolContract = proxy.protocolContractAddress();
        address originalRecipient = proxy.protocolFeeRecipient();
        bool originalPaused = proxy.paused();
        emit log_named_address("proxy", proxyAddr);
        emit log_named_address("proxyAdmin", admin);
        emit log_named_address("owner", ownerAddr);
        emit log_named_address("original impl", originalImpl);
        emit log_named_uint("original protocolSharePercent", originalShare);
        // Reproduce ENG-2548 on the CURRENT impl: an out-of-range share is
        // accepted (no bound). Proves the fix is not yet live on-chain.
        vm.prank(ownerAddr);
        proxy.setProtocolSharePercent(200);
        assertEq(proxy.protocolSharePercent(), 200, "pre-fix impl should accept >100 (vuln repro)");
        // Restore the original share so the no-regression asserts below are meaningful.
        vm.prank(ownerAddr);
        proxy.setProtocolSharePercent(originalShare);
        // Perform the upgrade exactly as production will: proxy admin calls
        // upgradeToAndCall with empty data (no reinitializer — storage layout
        // is unchanged by this fix).
        FabricaFeeCollector newImpl = new FabricaFeeCollector();
        vm.prank(admin);
        proxy.upgradeToAndCall(address(newImpl), "");
        assertEq(proxy.implementation(), address(newImpl), "impl not updated");
        // No-regression: persistent business state is preserved across the upgrade.
        assertEq(proxy.owner(), ownerAddr, "owner regressed");
        assertEq(proxy.protocolSharePercent(), originalShare, "share regressed");
        assertEq(proxy.protocolContractAddress(), originalProtocolContract, "protocolContract regressed");
        assertEq(proxy.protocolFeeRecipient(), originalRecipient, "recipient regressed");
        assertEq(proxy.paused(), originalPaused, "paused regressed");
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

    function test_fork_sepolia_prod() public {
        if (!_forkOrSkip(ForkConfig("SEPOLIA_RPC_URL", "sepolia", SEPOLIA_BLOCK, ""))) return;
        _verifyUpgrade(SEPOLIA_PROD);
    }

    function test_fork_sepolia_staging() public {
        if (!_forkOrSkip(ForkConfig("SEPOLIA_RPC_URL", "sepolia", SEPOLIA_BLOCK, ""))) return;
        _verifyUpgrade(SEPOLIA_STAGING);
    }

    function test_fork_sepolia_develop() public {
        if (!_forkOrSkip(ForkConfig("SEPOLIA_RPC_URL", "sepolia", SEPOLIA_BLOCK, ""))) return;
        _verifyUpgrade(SEPOLIA_DEVELOP);
    }

    function test_fork_mainnet_prod() public {
        if (!_forkOrSkip(ForkConfig("MAINNET_RPC_URL", "mainnet", MAINNET_BLOCK, ""))) return;
        _verifyUpgrade(MAINNET_PROD);
    }

    function test_fork_mainnet_develop() public {
        if (!_forkOrSkip(ForkConfig("MAINNET_RPC_URL", "mainnet", MAINNET_BLOCK, ""))) return;
        _verifyUpgrade(MAINNET_DEVELOP);
    }

    function test_fork_mainnet_staging() public {
        if (!_forkOrSkip(ForkConfig("MAINNET_RPC_URL", "mainnet", MAINNET_BLOCK, ""))) return;
        _verifyUpgrade(MAINNET_STAGING);
    }
}
