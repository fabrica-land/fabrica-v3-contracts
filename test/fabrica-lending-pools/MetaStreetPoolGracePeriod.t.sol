// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/Pool.sol";
import "../../src/fabrica-lending-pools/interfaces/IPool.sol";
import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./concretes/TestLiquidatablePool.sol";
import "./concretes/MockCollateralLiquidator.sol";
import "./concretes/TestERC20.sol";
import "./concretes/TestERC721.sol";

/**
 * Liquidation grace-period tests covering Fabrica ENG-3113: liquidate() is
 * gated until block.timestamp passes maturity + the pool's constructor
 * grace period; default-matured loans inside the window can still be cured
 * via the open-payoff path (ENG-3076).
 *
 * Non-fork. Uses TestLiquidatablePool with a trivial interest model
 * (repayment == principal) and a no-op MockCollateralLiquidator — the focus
 * is the time-based guard and the loan-status transitions, not auction
 * pricing or collateral routing.
 */
contract MetaStreetPoolGracePeriodTest is Test {
    /* Mirror IPool.LoanOriginated so vm.getRecordedLogs() can identify it by topic. */
    event LoanOriginated(bytes32 indexed loanReceiptHash, bytes loanReceipt);

    TestLiquidatablePool internal pool;
    MockCollateralLiquidator internal liquidator;
    TestERC20 internal currency;
    TestERC721 internal nft;
    ERC20DepositTokenImplementation internal erc20DepositTokenImpl;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidatorCaller = makeAddr("liquidator-caller");

    /* TICK encodes limit=1000 ether, durIdx=0, rateIdx=0, type=Absolute. */
    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint256 internal constant LENDER_DEPOSIT = 1000 ether;
    uint256 internal constant PRINCIPAL = 100 ether;
    uint64 internal constant DURATION = 7 days;
    uint64 internal constant GRACE_PERIOD = 20 days;
    uint256 internal constant NFT_ID = 1;

    function setUp() public {
        /* Anchor to a realistic timestamp so maturity math never underflows. */
        vm.warp(1_700_000_000);
        currency = new TestERC20("Test USDC", "tUSDC", 18);
        nft = new TestERC721("Test NFT", "tNFT");
        erc20DepositTokenImpl = new ERC20DepositTokenImplementation();
        liquidator = new MockCollateralLiquidator();
        pool = new TestLiquidatablePool(address(erc20DepositTokenImpl), address(liquidator), GRACE_PERIOD);

        uint64[] memory durations = new uint64[](1);
        durations[0] = DURATION;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        pool.initialize(address(currency), durations, rates);

        currency.mint(lender, LENDER_DEPOSIT);
        vm.prank(lender);
        currency.approve(address(pool), type(uint256).max);
        vm.prank(lender);
        pool.deposit(TICK, LENDER_DEPOSIT, 1);

        nft.mint(borrower, NFT_ID);
        vm.prank(borrower);
        nft.setApprovalForAll(address(pool), true);
    }

    /* Borrow PRINCIPAL against the NFT as `borrower`. Returns the encoded loan
       receipt and its hash, captured from the LoanOriginated event. */
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
                /* Non-indexed bytes payload is abi.encode(bytes). */
                encodedLoanReceipt = abi.decode(logs[i].data, (bytes));
                return (encodedLoanReceipt, loanReceiptHash);
            }
        }
        revert("LoanOriginated event not found");
    }

    function test_grace_period_getter_returns_configured_value() public view {
        assertEq(pool.liquidationGracePeriod(), GRACE_PERIOD, "grace period getter");
    }

    function test_liquidate_reverts_before_maturity() public {
        (bytes memory receipt,) = _borrow();
        uint256 maturity = block.timestamp + DURATION;
        /* One second before maturity — not even expired yet. */
        vm.warp(maturity - 1);
        vm.prank(liquidatorCaller);
        vm.expectRevert(IPool.LoanNotExpired.selector);
        pool.liquidate(receipt);
    }

    function test_liquidate_reverts_during_grace() public {
        (bytes memory receipt, bytes32 hash) = _borrow();
        uint256 maturity = block.timestamp + DURATION;
        /* Past maturity (defaulted) but inside the grace window. */
        vm.warp(maturity + 1);
        vm.prank(liquidatorCaller);
        vm.expectRevert(IPool.LoanNotExpired.selector);
        pool.liquidate(receipt);
        /* State unchanged: loan still Active, pool still escrows collateral. */
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Active), "loan still active");
        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral still escrowed");
    }

    function test_liquidate_reverts_at_exact_grace_boundary() public {
        (bytes memory receipt,) = _borrow();
        uint256 maturity = block.timestamp + DURATION;
        /* Exactly at maturity + grace. Guard is `<=`, so this still reverts. */
        vm.warp(maturity + GRACE_PERIOD);
        vm.prank(liquidatorCaller);
        vm.expectRevert(IPool.LoanNotExpired.selector);
        pool.liquidate(receipt);
    }

    function test_liquidate_succeeds_after_grace() public {
        (bytes memory receipt, bytes32 hash) = _borrow();
        uint256 maturity = block.timestamp + DURATION;
        /* One second past the end of the grace window. */
        vm.warp(maturity + GRACE_PERIOD + 1);
        vm.prank(liquidatorCaller);
        pool.liquidate(receipt);
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Liquidated), "loan liquidated");
    }

    function test_repay_during_grace_clears_loan() public {
        (bytes memory receipt, bytes32 hash) = _borrow();
        uint256 maturity = block.timestamp + DURATION;
        /* Borrower cures inside the grace window via the open-payoff path. */
        vm.warp(maturity + 1);
        currency.mint(borrower, PRINCIPAL);
        vm.prank(borrower);
        currency.approve(address(pool), type(uint256).max);

        vm.prank(borrower);
        uint256 repaid = pool.repay(receipt);

        assertEq(repaid, PRINCIPAL, "repayment amount");
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Repaid), "loan repaid");
        assertEq(nft.ownerOf(NFT_ID), borrower, "collateral returned to borrower");
    }

    function test_liquidate_after_cure_reverts() public {
        (bytes memory receipt, bytes32 hash) = _borrow();
        uint256 maturity = block.timestamp + DURATION;
        vm.warp(maturity + 1);
        currency.mint(borrower, PRINCIPAL);
        vm.prank(borrower);
        currency.approve(address(pool), type(uint256).max);
        vm.prank(borrower);
        pool.repay(receipt);
        /* After grace expires, a cured loan can no longer be liquidated. */
        vm.warp(maturity + GRACE_PERIOD + 1);
        vm.prank(liquidatorCaller);
        vm.expectRevert(IPool.InvalidLoanReceipt.selector);
        pool.liquidate(receipt);
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Repaid), "loan stays repaid");
    }
}
