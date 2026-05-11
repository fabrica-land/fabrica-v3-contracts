// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./concretes/TestPool.sol";

/**
 * Sepolia-fork test for Pool.depositFor end-to-end against real Sepolia USDC.
 * Run with: forge test --match-contract MetaStreetPoolDepositForSepoliaForkTest \
 *                       --fork-url $SEPOLIA_RPC_URL -vvv
 *
 * When run without --fork-url, the onlyFork modifier short-circuits each test
 * (Sepolia USDC bytecode is absent on the local 31337 chain). Mirrors the skip
 * pattern in FabricaTokenSepoliaFork.t.sol.
 */
contract MetaStreetPoolDepositForSepoliaForkTest is Test {
    /* Circle's USDC on Sepolia (6 decimals). */
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    TestPool internal pool;

    address internal payer = makeAddr("fork-payer");
    address internal recipient = makeAddr("fork-recipient");

    /* USDC scales by 10^12 inside Pool, so a 1000-USDC tick limit becomes 1000e18 internally. */
    uint128 internal constant TICK = uint128((1000 ether) << 8);
    uint256 internal constant DEPOSIT_AMOUNT = 100e6;
    uint256 internal constant MIN_SHARES = 1;

    modifier onlyFork() {
        if (USDC.code.length == 0) return;
        _;
    }

    function setUp() public {
        if (USDC.code.length == 0) return;
        ERC20DepositTokenImplementation impl = new ERC20DepositTokenImplementation();
        pool = new TestPool(address(impl));
        uint64[] memory durations = new uint64[](1);
        durations[0] = 7 days;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        pool.initialize(USDC, durations, rates);
        deal(USDC, payer, 10_000e6);
        vm.prank(payer);
        (bool ok,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", address(pool), type(uint256).max));
        require(ok, "approve failed");
    }

    function _balance(address who) internal view returns (uint256 bal) {
        (bool ok, bytes memory data) = USDC.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        bal = abi.decode(data, (uint256));
    }

    function _shares(address account, uint128 tick) internal view returns (uint128 shares) {
        (shares,) = pool.deposits(account, tick);
    }

    function test_fork_depositFor_creditsRecipient() public onlyFork {
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        assertGt(shares, 0, "shares minted");
        assertEq(_shares(recipient, TICK), uint128(shares), "recipient credited");
        assertEq(_shares(payer, TICK), 0, "payer not credited");
        assertEq(_balance(payer), 10_000e6 - DEPOSIT_AMOUNT, "payer USDC debited");
        assertEq(_balance(address(pool)), DEPOSIT_AMOUNT, "pool received USDC");
    }

    function test_fork_recipient_canRedeemAndWithdraw() public onlyFork {
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.prank(recipient);
        uint128 redemptionId = pool.redeem(TICK, shares);
        uint256 recipientUsdcBefore = _balance(recipient);
        vm.prank(recipient);
        (uint256 withdrawnShares, uint256 withdrawnAmount) = pool.withdraw(TICK, redemptionId);
        assertEq(withdrawnShares, shares, "all shares withdrawn");
        assertGt(withdrawnAmount, 0, "withdrew non-zero amount");
        assertEq(_balance(recipient) - recipientUsdcBefore, withdrawnAmount, "recipient received USDC");
    }

    function test_fork_payer_cannotWithdrawRecipientShares() public onlyFork {
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.expectRevert(IPool.InsufficientShares.selector);
        vm.prank(payer);
        pool.redeem(TICK, shares);
    }
}
