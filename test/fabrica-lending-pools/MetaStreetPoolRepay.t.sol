// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/interfaces/IPool.sol";
import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./concretes/TestRepayablePool.sol";
import "./concretes/TestERC20.sol";
import "./concretes/TestERC721.sol";

/**
 * Repay-path tests covering ENG-3076: anyone may close a loan; collateral
 * still goes to the original borrower; refinance remains borrower-only.
 *
 * Non-fork. Uses TestRepayablePool with a trivial interest model so that
 * repayment == principal — the access-control surface is the focus, not the
 * pricing math.
 */
contract MetaStreetPoolRepayTest is Test {
    /* Mirror IPool.LoanOriginated so vm.getRecordedLogs() can identify it by topic. */
    event LoanOriginated(bytes32 indexed loanReceiptHash, bytes loanReceipt);

    TestRepayablePool internal pool;
    TestERC20 internal currency;
    TestERC721 internal nft;
    ERC20DepositTokenImplementation internal erc20DepositTokenImpl;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal thirdParty = makeAddr("third-party");

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
        pool = new TestRepayablePool(address(erc20DepositTokenImpl));

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

    /* Borrow PRINCIPAL against the NFT as `borrower`. Captures the encoded
       loan receipt from the LoanOriginated event log. */
    function _borrow() internal returns (bytes memory encodedLoanReceipt) {
        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        vm.recordLogs();
        vm.prank(borrower);
        pool.borrow(PRINCIPAL, DURATION, address(nft), NFT_ID, PRINCIPAL, ticks, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pool) && logs[i].topics[0] == topic) {
                /* Non-indexed bytes payload is abi.encode(bytes). */
                encodedLoanReceipt = abi.decode(logs[i].data, (bytes));
                return encodedLoanReceipt;
            }
        }
        revert("LoanOriginated event not found");
    }

    function test_borrower_can_self_repay() public {
        bytes memory receipt = _borrow();
        /* repay() rejects same-block as borrow. */
        vm.warp(block.timestamp + 1);

        /* Borrower funds the repayment. */
        currency.mint(borrower, PRINCIPAL);
        vm.prank(borrower);
        currency.approve(address(pool), type(uint256).max);

        uint256 borrowerCurrencyBefore = currency.balanceOf(borrower);
        assertEq(nft.ownerOf(NFT_ID), address(pool), "pool holds collateral pre-repay");

        vm.prank(borrower);
        uint256 repaid = pool.repay(receipt);

        assertEq(repaid, PRINCIPAL, "repayment amount");
        assertEq(nft.ownerOf(NFT_ID), borrower, "collateral returned to borrower");
        assertEq(currency.balanceOf(borrower), borrowerCurrencyBefore - PRINCIPAL, "borrower paid");
    }

    function test_third_party_can_repay_collateral_to_borrower() public {
        bytes memory receipt = _borrow();
        vm.warp(block.timestamp + 1);

        /* Third party funds and approves the pool. */
        currency.mint(thirdParty, PRINCIPAL);
        vm.prank(thirdParty);
        currency.approve(address(pool), type(uint256).max);

        uint256 borrowerCurrencyBefore = currency.balanceOf(borrower);
        uint256 thirdPartyCurrencyBefore = currency.balanceOf(thirdParty);
        assertEq(nft.ownerOf(NFT_ID), address(pool), "pool holds collateral pre-repay");

        vm.prank(thirdParty);
        uint256 repaid = pool.repay(receipt);

        assertEq(repaid, PRINCIPAL, "repayment amount");
        /* Collateral lands at the ORIGINAL borrower, not the third party. */
        assertEq(nft.ownerOf(NFT_ID), borrower, "collateral returned to original borrower");
        /* Funds are pulled from the third party, not the borrower. */
        assertEq(currency.balanceOf(thirdParty), thirdPartyCurrencyBefore - PRINCIPAL, "third party paid");
        assertEq(currency.balanceOf(borrower), borrowerCurrencyBefore, "borrower's balance untouched");
    }

    function test_third_party_repay_reverts_when_under_allowance() public {
        bytes memory receipt = _borrow();
        vm.warp(block.timestamp + 1);

        /* Third party has funds but allowance is short by 1 wei. */
        currency.mint(thirdParty, PRINCIPAL);
        vm.prank(thirdParty);
        currency.approve(address(pool), PRINCIPAL - 1);

        vm.prank(thirdParty);
        /* TestERC20 reverts on allowance underflow (panic 0x11). Any revert
           is acceptable here — the contract refuses to transfer. */
        vm.expectRevert();
        pool.repay(receipt);

        /* State unchanged: pool still holds collateral. */
        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral still escrowed");
    }

    function test_third_party_repay_reverts_when_insufficient_balance() public {
        bytes memory receipt = _borrow();
        vm.warp(block.timestamp + 1);

        /* Third party has full allowance but only half the principal in tokens. */
        currency.mint(thirdParty, PRINCIPAL / 2);
        vm.prank(thirdParty);
        currency.approve(address(pool), type(uint256).max);

        vm.prank(thirdParty);
        vm.expectRevert();
        pool.repay(receipt);

        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral still escrowed");
    }

    function test_refinance_remains_borrower_only() public {
        bytes memory receipt = _borrow();
        vm.warp(block.timestamp + 1);

        /* Third party funds and approves. */
        currency.mint(thirdParty, PRINCIPAL * 2);
        vm.prank(thirdParty);
        currency.approve(address(pool), type(uint256).max);

        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        vm.prank(thirdParty);
        vm.expectRevert(IPool.InvalidCaller.selector);
        pool.refinance(receipt, PRINCIPAL, DURATION, PRINCIPAL, ticks, "");
    }

    function test_borrower_can_still_refinance() public {
        bytes memory receipt = _borrow();
        vm.warp(block.timestamp + 1);

        currency.mint(borrower, PRINCIPAL);
        vm.prank(borrower);
        currency.approve(address(pool), type(uint256).max);

        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        vm.prank(borrower);
        uint256 newRepayment = pool.refinance(receipt, PRINCIPAL, DURATION, PRINCIPAL, ticks, "");
        assertEq(newRepayment, PRINCIPAL, "refinanced repayment");
        /* Pool still holds collateral against the new loan. */
        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral still escrowed under new loan");
    }
}
