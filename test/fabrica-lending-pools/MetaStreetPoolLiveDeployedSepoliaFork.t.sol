// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/interfaces/IPool.sol";

/**
 * ENG-3115 — Full-coverage verification bound to the ACTUAL DEPLOYED Fabrica
 * lending pool on Sepolia (not a freshly-deployed TestPool).
 *
 * Every other *SepoliaFork test in this repo spins up a brand-new pool on the
 * fork and exercises freshly-compiled source. This suite instead binds to the
 * live BeaconProxy at 0x6C56…774c0B — so each call dispatches through the
 * on-chain UpgradeableBeacon into the deployed implementation bytecode
 * (0x78F794…9BB5, ENG-3231) over the pool's real storage. This is the
 * "as-shipped, no mocks" evidence for the deposit/redeem/withdraw LP surface
 * and the depositFor recipient behavior (ENG-3101), plus a codified snapshot of
 * the deployed identity/config that Phase A read with `cast`.
 *
 * Run:
 *   forge test --match-contract MetaStreetPoolLiveDeployedSepoliaForkTest \
 *              --fork-url $SEPOLIA_RPC_URL -vvv
 *
 * Without --fork-url the onlyFork modifier short-circuits (Sepolia USDC / pool
 * bytecode is absent on the clean 31337 chain), mirroring the repo's existing
 * fork-test skip convention so `forge test` in CI stays green without an RPC.
 * When a fork IS supplied, the identity test additionally asserts
 * block.chainid == Sepolia so a fork URL pointed at the wrong network fails
 * loudly instead of silently no-op'ing.
 *
 * Time-locked paths (default → grace → liquidate) and the signed-oracle borrow
 * origination are intentionally NOT driven against the live pool here — a live
 * testnet has no time-travel and we do not hold the oracle signer. Those are
 * covered by the grace/borrower fork suites (MetaStreetPoolGracePeriod*.t.sol,
 * MetaStreetPoolBorrowerForkUpgrade.t.sol) and, where cheap, by live EOA
 * transactions captured in the ENG-3115 execution report. The auction
 * liquidator (EnglishAuctionCollateralLiquidator) is vendored upstream-verbatim
 * @ 8ed467d with zero Fabrica modifications, so its bid/settle/anti-snipe
 * mechanics are upstream-audited; the only Fabrica-relevant auction surface is
 * the deploy-time auctionDuration config, asserted below as-shipped.
 */
interface IDeployedPool {
    function depositFor(address recipient, uint128 tick, uint256 amount, uint256 minShares) external returns (uint256);
    function deposit(uint128 tick, uint256 amount, uint256 minShares) external returns (uint256);
    function redeem(uint128 tick, uint256 shares) external returns (uint128);
    function withdraw(uint128 tick, uint128 redemptionId) external returns (uint256, uint256);
    function transfer(address from, address to, uint128 tick, uint256 shares) external;
    function deposits(address account, uint128 tick) external view returns (uint128 shares, uint128 redemptionId);
    function liquidationGracePeriod() external view returns (uint64);
    function IMPLEMENTATION_VERSION() external pure returns (string memory);
    function currencyToken() external view returns (address);
    function collateralLiquidator() external view returns (address);
    function getERC20DepositTokenImplementation() external view returns (address);
    function durations() external view returns (uint64[] memory);
    function rates() external view returns (uint64[] memory);
    function admin() external view returns (address);
}

interface ILiquidatorParams {
    function auctionDuration() external view returns (uint64);
    function timeExtensionWindow() external view returns (uint64);
    function timeExtension() external view returns (uint64);
    function minimumBidBasisPoints() external view returns (uint64);
}

interface IBeacon {
    function implementation() external view returns (address);
}

interface IOwnable {
    function owner() external view returns (address);
}

contract MetaStreetPoolLiveDeployedSepoliaForkTest is Test {
    /* Live Sepolia deployment (ENG-3078 stack; see LENDING-POOL-RUNBOOK.md). */
    address internal constant POOL = 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B;
    address internal constant BEACON = 0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e;
    address internal constant FACTORY = 0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83;
    address internal constant EXPECTED_IMPL = 0x78F794373E7B4b2fCF86987C70abdA0e12fE9BB5;
    address internal constant LIQUIDATOR = 0xc780FEe561fc6E50493C496a53c62518971ba9EF;
    address internal constant DEPOSIT_TOKEN_IMPL = 0x479c18dcEB406C88a0E05c86b9Ca02B6B043507B;
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    /* Deployer EOA that owns the beacon + factory on Sepolia (TESTNET_DEPLOYER). */
    address internal constant DEPLOYER = 0xBF03076547a99857b796717faF4034dea94569dF;

    IDeployedPool internal pool = IDeployedPool(POOL);

    address internal payer = makeAddr("live-payer");
    address internal recipient = makeAddr("live-recipient");
    address internal stranger = makeAddr("live-stranger");

    /* TICK encodes limit=1000 (18-decimal internal scale; represents 1000 USDC),
       durIdx=0, rateIdx=0, type=Absolute — the same encoding the other fork
       tests use; durIdx/rateIdx 0 are valid against the pool's 8 duration/rate
       tiers. */
    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint256 internal constant DEPOSIT_AMOUNT = 100e6;
    uint256 internal constant MIN_SHARES = 1;

    modifier onlyFork() {
        if (USDC.code.length == 0 || POOL.code.length == 0) return;
        _;
    }

    /* Fund + approve the common payer once per test. Guarded so it is inert on
       the clean 31337 chain (no Sepolia USDC bytecode to `deal` against); the
       funding-free tests (identity, auction, transfer, unknown-redemption) are
       unaffected by the extra balance. */
    function setUp() public {
        if (USDC.code.length == 0 || POOL.code.length == 0) return;
        deal(USDC, payer, 10_000e6);
        _approveMax(payer);
    }

    function _approveMax(address who) internal {
        vm.prank(who);
        (bool ok,) = USDC.call(abi.encodeWithSignature("approve(address,uint256)", POOL, type(uint256).max));
        require(ok, "approve failed");
    }

    function _balance(address who) internal view returns (uint256 bal) {
        (bool ok, bytes memory data) = USDC.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        bal = abi.decode(data, (uint256));
    }

    function _shares(address account) internal view returns (uint128 shares) {
        (shares,) = pool.deposits(account, TICK);
    }

    /* ---- Deployed identity / config (codifies Phase A cast reads) ---- */

    function test_live_deployed_identity_matches_source() public onlyFork {
        /* Fail loudly if --fork-url is pointed at a non-Sepolia network. */
        assertEq(block.chainid, 11155111, "fork must be Sepolia");
        assertEq(IBeacon(BEACON).implementation(), EXPECTED_IMPL, "beacon impl == current merged source (ENG-3231)");
        assertEq(IOwnable(BEACON).owner(), DEPLOYER, "beacon owner == deployer EOA");
        assertEq(IOwnable(FACTORY).owner(), DEPLOYER, "factory owner == deployer EOA");
        assertEq(pool.admin(), FACTORY, "pool admin == PoolFactory (factory-created)");
        assertEq(pool.IMPLEMENTATION_VERSION(), "2.15", "impl version");
        assertEq(pool.liquidationGracePeriod(), 1728000, "grace period 20 days (ENG-3113)");
        assertEq(pool.currencyToken(), USDC, "currency token is Sepolia USDC");
        assertEq(pool.collateralLiquidator(), LIQUIDATOR, "collateral liquidator immutable");
        assertEq(pool.getERC20DepositTokenImplementation(), DEPOSIT_TOKEN_IMPL, "deposit-token impl immutable");
        _assertTierSnapshot();
    }

    /* Full duration + rate tier snapshot (all 16 values), mirroring the deploy
       script (script/FabricaLendingPoolCreate.s.sol) so drift in ANY tier — not
       just the extremes — trips this codified as-shipped assertion. */
    function _assertTierSnapshot() internal view {
        uint64[8] memory expectedDurations =
            [uint64(62208000), 31104000, 23328000, 15552000, 10368000, 7776000, 5184000, 2592000];
        uint64[8] memory expectedRates =
            [uint64(1585489599), 2219685438, 3170979198, 4122272957, 4756468797, 5390664637, 6341958396, 7927447995];
        uint64[] memory durs = pool.durations();
        uint64[] memory rts = pool.rates();
        assertEq(durs.length, 8, "8 duration tiers");
        assertEq(rts.length, 8, "8 rate tiers");
        for (uint256 i; i < 8; i++) {
            assertEq(durs[i], expectedDurations[i], "duration tier drift");
            assertEq(rts[i], expectedRates[i], "rate tier drift");
        }
    }

    /* Records the deployed auction config. auctionDuration is 86400 (1 day) as
       shipped — ENG-3078 specifies 14 days (1209600). This asserts the AS-SHIPPED
       value so the discrepancy is codified, not the ticket's intended value. */
    function test_live_deployed_auction_params_as_shipped() public onlyFork {
        ILiquidatorParams liq = ILiquidatorParams(LIQUIDATOR);
        assertEq(liq.auctionDuration(), 86400, "auction duration AS-SHIPPED = 1 day (NOTE: ENG-3078 specs 14 days)");
        assertEq(liq.timeExtensionWindow(), 600, "anti-snipe window 10 min");
        assertEq(liq.timeExtension(), 900, "anti-snipe extension 15 min");
        assertEq(liq.minimumBidBasisPoints(), 200, "min bid increment 2%");
    }

    /* ---- depositFor: recipient credit, payer pull (ENG-3101) ---- */

    function test_live_depositFor_creditsRecipient_debitsPayer() public onlyFork {
        uint256 payerBefore = _balance(payer);
        uint256 poolBefore = _balance(POOL);
        uint128 recipientSharesBefore = _shares(recipient);
        uint128 payerSharesBefore = _shares(payer);

        vm.recordLogs();
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);

        assertGt(shares, 0, "shares minted");
        assertEq(uint256(_shares(recipient) - recipientSharesBefore), shares, "recipient credited the minted shares");
        assertEq(_shares(payer), payerSharesBefore, "payer NOT credited");
        assertEq(payerBefore - _balance(payer), DEPOSIT_AMOUNT, "payer USDC debited by deposit amount");
        assertEq(_balance(POOL) - poolBefore, DEPOSIT_AMOUNT, "pool USDC increased by deposit amount");
        _assertDepositedEvent(recipient, shares);
    }

    function _assertDepositedEvent(address beneficiary, uint256 shares) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Deposited(address,uint128,uint256,uint256)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == POOL && logs[i].topics.length == 3 && logs[i].topics[0] == topic) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), beneficiary, "Deposited.account == recipient");
                assertEq(uint256(logs[i].topics[2]), uint256(TICK), "Deposited.tick");
                (uint256 amount, uint256 evShares) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(amount, DEPOSIT_AMOUNT, "Deposited.amount");
                assertEq(evShares, shares, "Deposited.shares");
                found = true;
            }
        }
        assertTrue(found, "Deposited event emitted for recipient");
    }

    /* deposit() forwards msg.sender as the recipient to depositFor, so shares
       credit the caller. (Pool.deposit passes msg.sender directly; DepositLogic
       reverts InvalidRecipient on a zero recipient — there is no address(0)
       coalescing on this path.) */
    function test_live_deposit_creditsSelf() public onlyFork {
        uint128 before = _shares(payer);
        vm.prank(payer);
        uint256 shares = pool.deposit(TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        assertEq(uint256(_shares(payer) - before), shares, "deposit credits msg.sender");
    }

    /* depositFor(recipient == msg.sender) is equivalent to deposit(): the caller
       is credited (plan case B5). */
    function test_live_depositFor_self_creditsSelf() public onlyFork {
        uint128 before = _shares(payer);
        vm.prank(payer);
        uint256 shares = pool.depositFor(payer, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        assertEq(uint256(_shares(payer) - before), shares, "depositFor(self) credits msg.sender like deposit()");
    }

    /* Recipient (not payer) controls the position: can redeem + withdraw. The
       test's own depositFor adds the available liquidity the redemption draws
       from, so the same-block withdraw settles in full. */
    function test_live_recipient_canRedeemAndWithdraw() public onlyFork {
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);

        vm.prank(recipient);
        uint128 redemptionId = pool.redeem(TICK, shares);
        uint256 recipientUsdcBefore = _balance(recipient);
        vm.prank(recipient);
        (uint256 withdrawnShares, uint256 withdrawnAmount) = pool.withdraw(TICK, redemptionId);
        assertEq(withdrawnShares, shares, "all shares withdrawn");
        assertGt(withdrawnAmount, 0, "withdrew non-zero amount");
        assertEq(_balance(recipient) - recipientUsdcBefore, withdrawnAmount, "recipient received the USDC");
    }

    /* Funding a deposit for a recipient does NOT let the payer redeem it: the
       payer's own tick balance is 0, so redeem reverts InsufficientShares — a
       balance guard keyed on deposits[msg.sender][tick], not a distinct
       authorization check (any zero-balance caller reverts identically). */
    function test_live_payer_cannotRedeemSharesItFunded() public onlyFork {
        vm.prank(payer);
        uint256 shares = pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, MIN_SHARES);
        vm.expectRevert(IPool.InsufficientShares.selector);
        vm.prank(payer);
        pool.redeem(TICK, shares);
    }

    /* depositFor rejects a zero-address recipient (DepositLogic guard, which
       fires before any currency pull). */
    function test_live_depositFor_rejectsZeroRecipient() public onlyFork {
        vm.expectRevert(IPool.InvalidRecipient.selector);
        vm.prank(payer);
        pool.depositFor(address(0), TICK, DEPOSIT_AMOUNT, MIN_SHARES);
    }

    /* minShares slippage guard: requesting more shares than mintable reverts.
       type(uint128).max is far above the ~1e20 shares a 100-USDC deposit mints,
       yet fits uint128 so the deposit reaches the minShares check rather than
       tripping an earlier SafeCast on the bound itself. */
    function test_live_depositFor_respectsMinSharesSlippage() public onlyFork {
        vm.expectRevert(IPool.InsufficientShares.selector);
        vm.prank(payer);
        pool.depositFor(recipient, TICK, DEPOSIT_AMOUNT, uint256(type(uint128).max));
    }

    /* withdraw of an unknown / never-created redemptionId reverts
       InvalidRedemptionStatus: redemption.pending == 0 on a default-zero slot
       (DepositLogic._withdraw). Note this covers ONLY the missing-id case — a
       genuinely-queued redemption has pending != 0 and does NOT hit this revert;
       it returns (0, 0) until liquidity frees up. A fresh stranger + arbitrary id
       guarantees the zero slot. */
    function test_live_withdraw_rejectsUnknownRedemption() public onlyFork {
        vm.expectRevert(IPool.InvalidRedemptionStatus.selector);
        vm.prank(stranger);
        pool.withdraw(TICK, 99999);
    }

    /* Authorization: transfer() is deposit-token-only; a stranger call reverts. */
    function test_live_transfer_rejectsNonDepositTokenCaller() public onlyFork {
        vm.expectRevert(IPool.InvalidCaller.selector);
        vm.prank(stranger);
        pool.transfer(stranger, recipient, TICK, 1);
    }
}
