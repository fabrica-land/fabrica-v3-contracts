// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/Pool.sol";
import "../../src/fabrica-lending-pools/interfaces/IPool.sol";
import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./concretes/TestLiquidatablePool.sol";
import "./concretes/MockCollateralLiquidator.sol";
import "./concretes/TestERC721.sol";

/**
 * Mainnet-fork end-to-end test for the Fabrica ENG-3113 liquidation grace
 * period. Exercises the guard against production-shaped USDC bytecode (the
 * SafeERC20 dispatch / decimals path) rather than a clean-room mock currency.
 *
 * Run with: forge test --match-contract MetaStreetPoolGracePeriodMainnetForkTest \
 *                       --fork-url $MAINNET_RPC_URL -vvv
 *
 * When run without --fork-url, the onlyFork modifier short-circuits each test
 * (mainnet USDC bytecode is absent on the local 31337 chain). Mirrors the skip
 * pattern in MetaStreetPoolRepaySepoliaForkTest.
 *
 * The pool is freshly deployed on the fork — there is no pre-existing
 * Fabrica-forked pool on mainnet yet (that's the downstream mainnet-deploy
 * ticket this one blocks). A no-op MockCollateralLiquidator stands in for the
 * auction liquidator: the guard under test runs in Pool.liquidate() before the
 * liquidator hand-off, so the assertion is on the time gate + status
 * transition, not auction proceeds.
 */
contract MetaStreetPoolGracePeriodMainnetForkTest is Test {
    /* Circle's USDC on Ethereum mainnet (6 decimals). */
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    TestLiquidatablePool internal pool;
    MockCollateralLiquidator internal liquidator;
    TestERC721 internal nft;

    address internal lender = makeAddr("fork-lender");
    address internal borrower = makeAddr("fork-borrower");
    address internal liquidatorCaller = makeAddr("fork-liquidator-caller");

    /* USDC scales by 10^12 inside Pool, so 1000-USDC tick limit becomes 1000e18 internally. */
    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint256 internal constant LENDER_DEPOSIT = 1000e6;
    uint256 internal constant PRINCIPAL = 100e6;
    uint64 internal constant DURATION = 7 days;
    uint64 internal constant GRACE_PERIOD = 20 days;
    uint256 internal constant NFT_ID = 1;

    modifier onlyFork() {
        if (USDC.code.length == 0) return;
        _;
    }

    function setUp() public {
        if (USDC.code.length == 0) return;
        nft = new TestERC721("Fork Test NFT", "fNFT");
        ERC20DepositTokenImplementation impl = new ERC20DepositTokenImplementation();
        liquidator = new MockCollateralLiquidator();
        pool = new TestLiquidatablePool(address(impl), address(liquidator), GRACE_PERIOD);

        uint64[] memory durations = new uint64[](1);
        durations[0] = DURATION;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        pool.initialize(USDC, durations, rates);

        deal(USDC, lender, LENDER_DEPOSIT);
        vm.prank(lender);
        _approve(USDC, address(pool), type(uint256).max);
        vm.prank(lender);
        pool.deposit(TICK, LENDER_DEPOSIT, 1);

        nft.mint(borrower, NFT_ID);
        vm.prank(borrower);
        nft.setApprovalForAll(address(pool), true);
    }

    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }

    function _borrow() internal returns (bytes memory encodedLoanReceipt, bytes32 loanReceiptHash) {
        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        vm.recordLogs();
        vm.prank(borrower);
        pool.borrow(PRINCIPAL, DURATION, address(nft), NFT_ID, PRINCIPAL, ticks, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pool) && logs[i].topics.length > 1 && logs[i].topics[0] == topic) {
                loanReceiptHash = logs[i].topics[1];
                encodedLoanReceipt = abi.decode(logs[i].data, (bytes));
                return (encodedLoanReceipt, loanReceiptHash);
            }
        }
        revert("LoanOriginated event not found");
    }

    function test_fork_liquidate_reverts_during_grace() public onlyFork {
        (bytes memory receipt, bytes32 hash) = _borrow();
        uint256 maturity = block.timestamp + DURATION;
        vm.warp(maturity + 1);
        vm.prank(liquidatorCaller);
        vm.expectRevert(IPool.LoanNotExpired.selector);
        pool.liquidate(receipt);
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Active), "loan still active");
    }

    function test_fork_liquidate_succeeds_after_grace() public onlyFork {
        (bytes memory receipt, bytes32 hash) = _borrow();
        uint256 maturity = block.timestamp + DURATION;
        vm.warp(maturity + GRACE_PERIOD + 1);
        vm.prank(liquidatorCaller);
        pool.liquidate(receipt);
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Liquidated), "loan liquidated");
    }

    function test_fork_repay_during_grace_clears_loan() public onlyFork {
        (bytes memory receipt, bytes32 hash) = _borrow();
        uint256 maturity = block.timestamp + DURATION;
        vm.warp(maturity + 1);
        deal(USDC, borrower, PRINCIPAL);
        vm.prank(borrower);
        _approve(USDC, address(pool), type(uint256).max);
        vm.prank(borrower);
        uint256 repaid = pool.repay(receipt);
        assertEq(repaid, PRINCIPAL, "repayment amount");
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Repaid), "loan repaid");
        assertEq(nft.ownerOf(NFT_ID), borrower, "collateral returned to borrower");
    }
}
