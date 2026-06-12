// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/interfaces/IPool.sol";
import "../../src/fabrica-lending-pools/LoanReceipt.sol";
import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./concretes/TestLiquidatablePool.sol";
import "./concretes/MockCollateralLiquidator.sol";
import "./concretes/TestERC20.sol";
import "./concretes/TestERC721.sol";

/**
 * ENG-3231: borrow() takes a required designated `borrower` parameter (breaking
 * change vs upstream MetaStreet). The designated borrower becomes the
 * borrower-of-record / beneficial owner of the (encumbered) collateral, while
 * collateral is pulled from msg.sender (the caller/router) and principal is
 * sent to msg.sender. This is the financed-buy primitive: a router funds the
 * purchase and takes the proceeds; the designated party ends up owning the
 * collateral and owing the loan. No authorization is enforced (Tim's lean: the
 * obligation receipt is freely transferable, like accepting an ERC-721).
 *
 * Non-fork. TestLiquidatablePool with a trivial interest model (repayment ==
 * principal, adminFee == 0) so the designated-borrower routing is the focus,
 * not the pricing math.
 */
contract MetaStreetPoolBorrowerParamTest is Test {
    /* Mirror IPool.LoanOriginated so vm.getRecordedLogs() can identify it by topic. */
    event LoanOriginated(bytes32 indexed loanReceiptHash, bytes loanReceipt);

    TestLiquidatablePool internal pool;
    MockCollateralLiquidator internal liquidator;
    TestERC20 internal currency;
    TestERC721 internal nft;
    ERC20DepositTokenImplementation internal erc20DepositTokenImpl;

    address internal lender = makeAddr("lender");
    /* The caller/router: owns the collateral, funds the purchase, takes principal. */
    address internal router = makeAddr("router");
    /* The designated borrower-of-record / beneficial owner. */
    address internal designated = makeAddr("designated");
    address internal stranger = makeAddr("stranger");

    /* TICK encodes limit=1000 ether, durIdx=0, rateIdx=0, type=Absolute. */
    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint256 internal constant LENDER_DEPOSIT = 1000 ether;
    uint256 internal constant PRINCIPAL = 100 ether;
    uint64 internal constant DURATION = 7 days;
    uint256 internal constant NFT_ID = 1;

    function setUp() public {
        currency = new TestERC20("Test USDC", "tUSDC", 18);
        nft = new TestERC721("Test NFT", "tNFT");
        erc20DepositTokenImpl = new ERC20DepositTokenImplementation();
        liquidator = new MockCollateralLiquidator();
        /* Grace period 0 so liquidate() is allowed immediately after maturity. */
        pool = new TestLiquidatablePool(address(erc20DepositTokenImpl), address(liquidator), 0);

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

        /* The router owns the collateral (it is funding the purchase). */
        nft.mint(router, NFT_ID);
        vm.prank(router);
        nft.setApprovalForAll(address(pool), true);
    }

    /* Borrow PRINCIPAL against the router's NFT, designating `borrowerOfRecord`
       as borrower-of-record. The router is always msg.sender. Returns the
       encoded loan receipt captured from the LoanOriginated event. */
    function _borrowTo(address borrowerOfRecord) internal returns (bytes memory encodedLoanReceipt) {
        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        vm.recordLogs();
        vm.prank(router);
        pool.borrow(borrowerOfRecord, PRINCIPAL, DURATION, address(nft), NFT_ID, PRINCIPAL, ticks, "");
        return _findLoanReceipt(vm.getRecordedLogs());
    }

    /* Extract the encoded loan receipt from the most recent LoanOriginated log
       emitted by the pool. */
    function _findLoanReceipt(Vm.Log[] memory logs) internal view returns (bytes memory encodedLoanReceipt) {
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter == address(pool) && entry.topics.length > 0 && entry.topics[0] == topic) {
                /* Non-indexed bytes payload is abi.encode(bytes). */
                return abi.decode(entry.data, (bytes));
            }
        }
        revert("LoanOriginated event not found");
    }

    function test_designated_borrower_is_borrower_of_record() public {
        uint256 routerCurrencyBefore = currency.balanceOf(router);

        bytes memory receipt = _borrowTo(designated);

        /* Borrower-of-record is the designated address, not the caller. */
        LoanReceipt.LoanReceiptV2 memory lr = pool.decodeLoanReceipt(receipt);
        assertEq(lr.borrower, designated, "borrower-of-record is the designated address");

        /* Collateral is pulled from msg.sender (router) into the pool. */
        assertEq(nft.ownerOf(NFT_ID), address(pool), "pool escrows collateral pulled from caller");

        /* Principal is sent to msg.sender (router), never to the designated borrower. */
        assertEq(currency.balanceOf(router), routerCurrencyBefore + PRINCIPAL, "principal to caller/msg.sender");
        assertEq(currency.balanceOf(designated), 0, "designated borrower receives no principal");
    }

    function test_repay_returns_collateral_to_designated_borrower() public {
        bytes memory receipt = _borrowTo(designated);
        /* repay() rejects same-block as borrow. */
        vm.warp(block.timestamp + 1);

        /* Anyone may fund and repay (ENG-3076). */
        currency.mint(stranger, PRINCIPAL);
        vm.prank(stranger);
        currency.approve(address(pool), type(uint256).max);

        vm.prank(stranger);
        uint256 repaid = pool.repay(receipt);

        assertEq(repaid, PRINCIPAL, "repayment amount");
        /* Collateral lands at the designated borrower — not the router/caller,
           not the payer. This is the redemption right of ownership. */
        assertEq(nft.ownerOf(NFT_ID), designated, "collateral redeemed to designated borrower");
    }

    function test_liquidation_surplus_goes_to_designated_borrower() public {
        bytes memory receipt = _borrowTo(designated);

        /* Default and pass the (zero) grace window, then liquidate. */
        vm.warp(block.timestamp + DURATION + 1);
        pool.liquidate(receipt);

        /* Simulate auction proceeds (principal + surplus) landing in the pool,
           then the liquidator settling via the async callback. The callback is
           a separate call (the reentrancy guard forbids it inside liquidate()). */
        uint256 surplus = 25 ether;
        uint256 proceeds = PRINCIPAL + surplus;
        currency.mint(address(pool), proceeds);

        vm.prank(address(liquidator));
        pool.onCollateralLiquidated(receipt, proceeds);

        /* Surplus (proceeds - repayment) accrues to the designated borrower. */
        assertEq(currency.balanceOf(designated), surplus, "liquidation surplus to designated borrower");
        /* The router only ever received the borrowed principal. */
        assertEq(currency.balanceOf(router), PRINCIPAL, "router holds only the borrowed principal");
    }

    function test_refinance_is_gated_to_designated_borrower() public {
        bytes memory receipt = _borrowTo(designated);
        vm.warp(block.timestamp + 1);

        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        /* The router originated the loan but is NOT the borrower-of-record, so
           it cannot refinance (refinance opens a new position; borrower-only). */
        currency.mint(router, PRINCIPAL);
        vm.prank(router);
        currency.approve(address(pool), type(uint256).max);
        vm.prank(router);
        vm.expectRevert(IPool.InvalidCaller.selector);
        pool.refinance(receipt, PRINCIPAL, DURATION, PRINCIPAL, ticks, "");

        /* The designated borrower CAN refinance, and the new loan preserves the
           designated borrower-of-record (guards against accidentally passing
           msg.sender instead of loanReceipt.borrower to _borrow). */
        currency.mint(designated, PRINCIPAL);
        vm.prank(designated);
        currency.approve(address(pool), type(uint256).max);
        vm.recordLogs();
        vm.prank(designated);
        uint256 newRepayment = pool.refinance(receipt, PRINCIPAL, DURATION, PRINCIPAL, ticks, "");

        assertEq(newRepayment, PRINCIPAL, "designated borrower refinanced");
        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral still escrowed under the new loan");
        LoanReceipt.LoanReceiptV2 memory newLr = pool.decodeLoanReceipt(_findLoanReceipt(vm.getRecordedLogs()));
        assertEq(newLr.borrower, designated, "refinance preserves the designated borrower-of-record");
    }

    function test_self_borrow_unchanged() public {
        /* borrower == msg.sender: collateral from self, principal to self,
           borrower-of-record == self (the normal path; router owns the NFT). */
        uint256 routerCurrencyBefore = currency.balanceOf(router);

        bytes memory receipt = _borrowTo(router);

        LoanReceipt.LoanReceiptV2 memory lr = pool.decodeLoanReceipt(receipt);
        assertEq(lr.borrower, router, "self-borrow: borrower-of-record is the caller");
        assertEq(currency.balanceOf(router), routerCurrencyBefore + PRINCIPAL, "self-borrow: principal to caller");
        assertEq(nft.ownerOf(NFT_ID), address(pool), "self-borrow: pool escrows collateral");
    }

    function test_borrow_reverts_on_zero_borrower() public {
        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        /* A zero borrower-of-record would make the collateral irrecoverable;
           the BorrowLogic guard fails closed. */
        vm.prank(router);
        vm.expectRevert(IPool.InvalidParameters.selector);
        pool.borrow(address(0), PRINCIPAL, DURATION, address(nft), NFT_ID, PRINCIPAL, ticks, "");
    }
}
