// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/interfaces/IPool.sol";
import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./concretes/TestPool.sol";
import "./concretes/TestERC20.sol";

contract MetaStreetPoolDepositForTest is Test {
    /* Mirror Pool.Deposited so vm.expectEmit can match it. */
    event Deposited(address indexed account, uint128 indexed tick, uint256 amount, uint256 shares);
    /* Mirror ERC20 Transfer for the wrapper-mint event check. */
    event Transfer(address indexed from, address indexed to, uint256 value);

    TestPool internal pool;
    TestERC20 internal token;
    ERC20DepositTokenImplementation internal erc20DepositTokenImpl;

    address internal payer = makeAddr("payer");
    address internal recipient = makeAddr("recipient");

    /* Single-duration, single-rate config. Tick: limit=1000e18, durIdx=0, rateIdx=0, type=0. */
    uint128 internal constant TICK = uint128((1000 ether) << 8);
    uint256 internal constant DEPOSIT_AMOUNT = 100 ether;
    uint256 internal constant MIN_SHARES = 1;

    function setUp() public {
        token = new TestERC20("Test Token", "TT", 18);
        erc20DepositTokenImpl = new ERC20DepositTokenImplementation();
        pool = new TestPool(address(erc20DepositTokenImpl));
        uint64[] memory durations = new uint64[](1);
        durations[0] = 7 days;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        pool.initialize(address(token), durations, rates);
        token.mint(payer, 10_000 ether);
        vm.prank(payer);
        token.approve(address(pool), type(uint256).max);
    }

    function _shares(address account, uint128 tick) internal view returns (uint128 shares) {
        (shares,) = pool.deposits(account, tick);
    }

    function test_depositFor_creditsRecipientNotPayer() public {
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        assertGt(shares, 0, "shares minted");
        assertEq(_shares(recipient, TICK), uint128(shares), "recipient credited");
        assertEq(_shares(payer, TICK), 0, "payer not credited");
    }

    function test_depositFor_pullsUsdcFromPayer() public {
        uint256 payerBefore = token.balanceOf(payer);
        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 poolBefore = token.balanceOf(address(pool));
        vm.prank(payer);
        pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        assertEq(token.balanceOf(payer), payerBefore - DEPOSIT_AMOUNT, "payer debited");
        assertEq(token.balanceOf(recipient), recipientBefore, "recipient untouched");
        assertEq(token.balanceOf(address(pool)), poolBefore + DEPOSIT_AMOUNT, "pool credited");
    }

    function test_depositFor_emitsDepositedWithRecipient() public {
        /* Predict the share count by snapshot/revert so we can assert on the full event payload */
        uint256 snapshotId = vm.snapshotState();
        vm.prank(payer);
        uint256 expectedShares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.revertToState(snapshotId);
        vm.expectEmit(true, true, true, true, address(pool));
        emit Deposited(recipient, TICK, DEPOSIT_AMOUNT, expectedShares);
        vm.prank(payer);
        pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
    }

    function test_depositFor_emitsERC20TransferToRecipient() public {
        address wrapper = pool.tokenize(TICK);
        /* Predict the share count by snapshot/revert so we can assert on the full event payload */
        uint256 snapshotId = vm.snapshotState();
        vm.prank(payer);
        uint256 expectedShares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.revertToState(snapshotId);
        vm.expectEmit(true, true, true, true, wrapper);
        emit Transfer(address(0), recipient, expectedShares);
        vm.prank(payer);
        pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
    }

    function test_depositFor_revertsOnZeroRecipient() public {
        vm.expectRevert(IPool.InvalidRecipient.selector);
        vm.prank(payer);
        pool.depositFor(address(0), TICK, DEPOSIT_AMOUNT, MIN_SHARES);
    }

    function test_depositFor_revertsOnInsufficientShares() public {
        /* uint128.max is the largest minShares that survives Pool's toUint128 cast,
           guaranteed above any achievable shares from a 100-token deposit. */
        vm.expectRevert(IPool.InsufficientShares.selector);
        vm.prank(payer);
        pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, type(uint128).max);
    }

    function test_deposit_unchanged_creditsMsgSender() public {
        vm.prank(payer);
        uint256 shares = pool.deposit(TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        assertGt(shares, 0, "shares minted");
        assertEq(_shares(payer, TICK), uint128(shares), "payer credited (legacy path)");
        assertEq(_shares(recipient, TICK), 0, "recipient not credited");
    }

    function test_recipientCanRedeem() public {
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.prank(recipient);
        uint128 redemptionId = pool.redeem(TICK, shares);
        assertEq(_shares(recipient, TICK), 0, "shares burned on redeem");
        uint256 recipientBalanceBefore = token.balanceOf(recipient);
        vm.prank(recipient);
        (uint256 withdrawnShares, uint256 withdrawnAmount) = pool.withdraw(TICK, redemptionId);
        assertEq(withdrawnShares, shares, "all shares withdrawn");
        assertEq(token.balanceOf(recipient) - recipientBalanceBefore, withdrawnAmount, "recipient received withdrawal");
        assertGt(withdrawnAmount, 0, "withdrew non-zero amount");
    }

    function test_payerCannotRedeemRecipientShares() public {
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.expectRevert(IPool.InsufficientShares.selector);
        vm.prank(payer);
        pool.redeem(TICK, shares);
    }

    function test_rebalance_unchanged() public {
        vm.prank(payer);
        uint256 shares = pool.deposit(TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.prank(payer);
        uint128 redemptionId = pool.redeem(TICK, shares);
        vm.prank(payer);
        pool.rebalance(TICK, TICK, redemptionId, MIN_SHARES);
        assertGt(_shares(payer, TICK), 0, "payer rebalanced into self");
        assertEq(_shares(recipient, TICK), 0, "rebalance does not credit anyone else");
    }

    /* ENG-3231: redeem's burn hook now fires from DepositLogic resolving the
       deposit-token address via its own ERC-7201 storage mirror. Asserting the
       Transfer fires from the SAME wrapper pool.tokenize/depositToken returns
       guards the duplicated DEPOSIT_TOKEN_STORAGE_LOCATION against divergence. */
    function test_redeem_emitsERC20BurnTransfer_viaLibrarySlotResolution() public {
        address wrapper = pool.tokenize(TICK);
        assertEq(wrapper, pool.depositToken(TICK), "tokenized wrapper matches accessor");
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.expectEmit(true, true, true, true, wrapper);
        emit Transfer(recipient, address(0), shares);
        vm.prank(recipient);
        pool.redeem(TICK, shares);
    }

    /* ENG-3231: rebalance into a tokenized destination tick must fire the mint
       hook via the moved DepositLogic.rebalance + its ERC-7201 slot resolution. */
    function test_rebalance_intoTokenizedTick_emitsERC20MintTransfer() public {
        address wrapper = pool.tokenize(TICK);
        vm.prank(payer);
        uint256 shares = pool.deposit(TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.prank(payer);
        uint128 redemptionId = pool.redeem(TICK, shares);
        /* Predict newShares by snapshot/revert so we can assert the full event. */
        uint256 snapshotId = vm.snapshotState();
        vm.prank(payer);
        (, uint256 newShares,) = pool.rebalance(TICK, TICK, redemptionId, MIN_SHARES);
        vm.revertToState(snapshotId);
        vm.expectEmit(true, true, true, true, wrapper);
        emit Transfer(address(0), payer, newShares);
        vm.prank(payer);
        pool.rebalance(TICK, TICK, redemptionId, MIN_SHARES);
    }

    /* ENG-3231: the transfer() caller check moved into DepositLogic and now
       resolves the deposit token via the ERC-7201 slot mirror; a non-deposit-
       token caller must still revert InvalidCaller. */
    function test_transfer_revertsForNonDepositTokenCaller() public {
        vm.expectRevert(IPool.InvalidCaller.selector);
        vm.prank(payer);
        pool.transfer(payer, recipient, TICK, 1);
    }
}
