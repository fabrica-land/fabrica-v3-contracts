// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../../src/fabrica-lending-pools/Pool.sol";
import "../../src/fabrica-lending-pools/interfaces/IPool.sol";
import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./GracePeriodTestBase.sol";
import "./concretes/MockCollateralLiquidator.sol";
import "./concretes/TestERC20.sol";

/**
 * Liquidation grace-period tests covering Fabrica ENG-3113: liquidate() is
 * gated until block.timestamp passes maturity + the pool's constructor
 * grace period; default-matured loans inside the window can still be cured
 * via the open-payoff path (ENG-3076).
 *
 * Non-fork. Uses TestLiquidatablePool (trivial interest model, repayment ==
 * principal) and a no-op MockCollateralLiquidator — the focus is the
 * time-based guard and the loan-status transitions.
 */
contract MetaStreetPoolGracePeriodTest is GracePeriodTestBase {
    MockCollateralLiquidator internal liquidator;
    TestERC20 internal currency;
    ERC20DepositTokenImplementation internal erc20DepositTokenImpl;

    address internal lender = makeAddr("lender");

    uint256 internal constant LENDER_DEPOSIT = 1000 ether;
    uint256 internal constant PRINCIPAL = 100 ether;

    function setUp() public {
        /* Anchor to a realistic timestamp so maturity math never underflows. */
        vm.warp(1_700_000_000);
        currency = new TestERC20("Test USDC", "tUSDC", 18);
        erc20DepositTokenImpl = new ERC20DepositTokenImplementation();
        liquidator = new MockCollateralLiquidator();
        _freshPool(GRACE_PERIOD);
    }

    /* Deploy + initialize a pool with the given grace period, seed lender
       liquidity, and mint/approve a fresh collateral NFT. Assigns the base
       `pool` and `nft`. Reused by setUp and the grace=0 regression test. */
    function _freshPool(uint64 grace) internal {
        pool = new TestLiquidatablePool(address(erc20DepositTokenImpl), address(liquidator), grace);
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

        nft = new TestERC721("Test NFT", "tNFT");
        nft.mint(borrower, NFT_ID);
        vm.prank(borrower);
        nft.setApprovalForAll(address(pool), true);
    }

    function test_grace_period_getter_returns_configured_value() public view {
        assertEq(pool.liquidationGracePeriod(), GRACE_PERIOD, "grace period getter");
    }

    function test_liquidate_reverts_before_maturity() public {
        (bytes memory receipt,) = _borrow(PRINCIPAL);
        uint256 maturity = block.timestamp + DURATION;
        /* One second before maturity — not even expired yet. */
        vm.warp(maturity - 1);
        vm.prank(liquidatorCaller);
        vm.expectRevert(IPool.LoanNotExpired.selector);
        pool.liquidate(receipt);
    }

    function test_liquidate_reverts_during_grace() public {
        (bytes memory receipt, bytes32 hash) = _borrow(PRINCIPAL);
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
        (bytes memory receipt,) = _borrow(PRINCIPAL);
        uint256 maturity = block.timestamp + DURATION;
        /* Exactly at maturity + grace. Guard is `<=`, so this still reverts. */
        vm.warp(maturity + GRACE_PERIOD);
        vm.prank(liquidatorCaller);
        vm.expectRevert(IPool.LoanNotExpired.selector);
        pool.liquidate(receipt);
    }

    function test_liquidate_succeeds_after_grace() public {
        (bytes memory receipt, bytes32 hash) = _borrow(PRINCIPAL);
        uint256 maturity = block.timestamp + DURATION;
        /* One second past the end of the grace window. */
        vm.warp(maturity + GRACE_PERIOD + 1);
        vm.expectEmit(true, false, false, true, address(pool));
        emit LoanLiquidated(hash);
        vm.prank(liquidatorCaller);
        pool.liquidate(receipt);
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Liquidated), "loan liquidated");
    }

    function test_repay_during_grace_clears_loan() public {
        (bytes memory receipt, bytes32 hash) = _borrow(PRINCIPAL);
        uint256 maturity = block.timestamp + DURATION;
        /* Borrower cures inside the grace window via the open-payoff path. */
        vm.warp(maturity + 1);
        currency.mint(borrower, PRINCIPAL);
        vm.prank(borrower);
        currency.approve(address(pool), type(uint256).max);

        vm.expectEmit(true, false, false, true, address(pool));
        emit LoanRepaid(hash, PRINCIPAL);
        vm.prank(borrower);
        uint256 repaid = pool.repay(receipt);

        assertEq(repaid, PRINCIPAL, "repayment amount");
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Repaid), "loan repaid");
        assertEq(nft.ownerOf(NFT_ID), borrower, "collateral returned to borrower");
    }

    function test_liquidate_after_cure_reverts() public {
        (bytes memory receipt, bytes32 hash) = _borrow(PRINCIPAL);
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

    /* Regression: a pool deployed with grace == 0 must reproduce the exact
       upstream maturity gate — liquidate reverts at the maturity instant and
       succeeds one second later. */
    function test_grace_zero_matches_upstream_maturity_gate() public {
        _freshPool(0);
        assertEq(pool.liquidationGracePeriod(), 0, "grace is zero");
        (bytes memory receipt, bytes32 hash) = _borrow(PRINCIPAL);
        uint256 maturity = block.timestamp + DURATION;
        /* At the exact maturity instant, `<=` still reverts. */
        vm.warp(maturity);
        vm.prank(liquidatorCaller);
        vm.expectRevert(IPool.LoanNotExpired.selector);
        pool.liquidate(receipt);
        /* One second past maturity, liquidation succeeds (no grace buffer). */
        vm.warp(maturity + 1);
        vm.prank(liquidatorCaller);
        pool.liquidate(receipt);
        assertEq(uint256(pool.loans(hash)), uint256(Pool.LoanStatus.Liquidated), "loan liquidated at maturity+1");
    }
}
