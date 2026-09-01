// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {ForkTestBase} from "./ForkTestBase.sol";
import {FabricaAttributeOracle} from "../src/FabricaAttributeOracle.sol";
import {FabricaOracleAggregator} from "../src/FabricaOracleAggregator.sol";

/// @notice Minimal view of the live Sepolia PoolFactory (source lives in metastreet-contracts-v2).
interface IPoolFactoryLike {
    function createProxied(address poolBeacon, bytes calldata params) external returns (address);
    function getPoolImplementations() external view returns (address[] memory);
    function isPool(address pool) external view returns (bool);
}

/// @notice Minimal view of the live WeightedRateERC1155CollectionPool (source lives in metastreet-contracts-v2).
interface ILaunchPool {
    function priceOracle() external view returns (address);
    function admin() external view returns (address);
    function currencyToken() external view returns (address);
    function IMPLEMENTATION_VERSION() external view returns (string memory);
    function durations() external view returns (uint64[] memory);
    function rates() external view returns (uint64[] memory);
    function deposit(uint128 tick, uint256 amount, uint256 minShares) external returns (uint256);
    function quote(
        uint256 principal,
        uint64 duration,
        address collateralToken,
        uint256 collateralTokenId,
        uint128[] calldata ticks,
        bytes calldata options
    ) external view returns (uint256);
    function borrow(
        address borrower,
        uint256 principal,
        uint64 duration,
        address collateralToken,
        uint256 collateralTokenId,
        uint256 maxRepayment,
        uint128[] calldata ticks,
        bytes calldata options
    ) external returns (uint256 repayment);
}

/**
 * ENG-3519 — Sepolia launch-pool acceptance REHEARSAL, pinned Sepolia fork.
 *
 * WHAT IS GENUINELY NEW HERE. metastreet-contracts-v2 already has fork suites that
 * bind to the live BeaconProxy and call `borrow()`
 * (`FabricaLendingPoolLiveDeployedSepoliaFork.t.sol`,
 * `FabricaLendingPoolRepaySepoliaFork.t.sol`,
 * `FabricaLendingPoolBorrowerForkUpgrade.t.sol`). What none of them do — and what
 * WP-B's `FabricaLendingPoolOracleTimelock.t.sol` does not do either, since it uses a
 * `MockAggregatorOracle` and asserts only at `pool.price(...)` — is put the REAL
 * `FabricaOracleAggregator` and the REAL `FabricaAttributeOracle` in the loop of a
 * real origination. That is this suite's contribution.
 *
 * ORACLE COUPLING — READ THIS BEFORE TRUSTING acceptance (a).
 * `Tick.decode` applies `oraclePrice` ONLY to Ratio-limit ticks; for an Absolute tick
 * the price is discarded. So a borrow sourced purely from Absolute ticks is
 * arithmetically INDEPENDENT of what the oracle returns — it proves the oracle is on
 * the borrow path and did not revert, nothing more. `test_oraclePriceMovesRatioCapacityButNotAbsolute`
 * is the test that actually binds price to dollars; the Absolute case is deliberately
 * kept alongside it to demonstrate the price-independence that ENG-3519's tick-policy
 * recommendation relies on.
 *
 * NO BROADCAST. Fork rehearsal only. This suite never signs or sends a
 * real-chain transaction; mainnet broadcasts remain operator-gated outside tests.
 *
 * Run:
 *   forge test --match-contract Eng3519LaunchPoolSepoliaForkTest -vv
 *
 * The fork is created and PINNED by `setUp` via `ForkTestBase`, so no `--fork-url` is
 * needed. Without `SEPOLIA_RPC_URL` the suite reports SKIPPED (never a silent pass);
 * set `FABRICA_REQUIRE_SEPOLIA_FV=1` to make a missing RPC a loud failure instead.
 */
contract Eng3519LaunchPoolSepoliaForkTest is ForkTestBase {
    /* ---------------------------------------------------------------------
       Live Sepolia stack. Addresses are documented in
       metastreet-contracts-v2/LENDING-POOL-RUNBOOK.md § Network Addresses.
       --------------------------------------------------------------------- */
    address internal constant FACTORY = 0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83;
    address internal constant BEACON = 0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e;
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant FABRICA_TOKEN = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    address internal constant LIVE_POOL = 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B;
    /* Measured runtime size of the live BeaconProxy. An EIP-1167 clone is exactly 45. */
    uint256 internal constant LIVE_POOL_RUNTIME_BYTES = 451;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    /* Pinned so the evidence is reproducible. This is the block whose TransferSingle
       delivered COLLATERAL_TOKEN_ID to COLLATERAL_HOLDER, so the fixture holds by
       construction rather than by luck at chain head. */
    uint256 internal constant FORK_BLOCK = 11_293_457;
    address internal constant COLLATERAL_HOLDER = 0xe962D614fC0d3E9D3AD0a60301Cb0BA314b72a19;
    uint256 internal constant COLLATERAL_TOKEN_ID = 3561233430243998108;

    /* ---------------------------------------------------------------------
       Aggregator config — MERGED start proposals, asserted below against the
       aggregator's LIVE storage. Not chosen here: maxJumpBps / maxDispersionBps
       are still "TBD" in WP-A's design-review table pending Tim/Fede.
       --------------------------------------------------------------------- */
    uint64 internal constant SEASONING_WINDOW = 24 hours;
    uint16 internal constant MAX_JUMP_BPS = 5000;
    uint16 internal constant MAX_DISPERSION_BPS = 20_000;
    uint8 internal constant MIN_LIVE_SOURCES = 2;

    uint256 internal constant VALIDATOR_ID = 1;
    uint8 internal constant SOURCE_PRYCD = 0;
    uint8 internal constant SOURCE_OPENAVM = 1;
    /* Synthetic fixture values, NOT real feed output. Deliberately ordered so the LOWER
       live price sits on the HIGHER source id: that makes the MIN assertion
       discriminating — it cannot be satisfied by "first write" or "lowest source id"
       semantics. Every step below is inside the fact store's write band
       (maxUpBps 1500 / maxDownBps 5000 against the previous value for that source). */
    /* Two seasoned values, deliberately UNEQUAL and with the lower one on the higher
       source id, so the floor's own MIN-over-sources is discriminating too — an
       aggregator that took MAX anywhere in the chain would produce 84_000e6, not
       80_000e6, and acceptance (a) would go red. */
    uint128 internal constant PRICE_SEASONED_PRYCD = 84_000e6;
    uint128 internal constant PRICE_SEASONED_OPENAVM = 80_000e6;
    uint128 internal constant PRICE_SEASONED = PRICE_SEASONED_OPENAVM;
    /* +15% from seasoned: exactly maxUpBps, which _enforceBand permits. */
    uint128 internal constant PRICE_PRYCD = 92_000e6;
    /* +10% from seasoned, and the live MIN. */
    uint128 internal constant PRICE_OPENAVM = 88_000e6;
    uint128 internal constant EXPECTED_LIVE_MIN = PRICE_OPENAVM;
    /* The temporal floor takes MIN(live MIN, seasoned MIN), so the seasoned value —
       deliberately below both live prices — is the usable price. That makes the floor
       genuinely load-bearing here rather than the no-op it would be if every
       observation were written at the same instant. */
    uint128 internal constant EXPECTED_USABLE_PRICE = PRICE_SEASONED;

    /* Absolute-limit tick: limit 50_000e18 (pool internals normalize currency to 18dp
       even though USDC is 6dp), durIdx 0, rateIdx 0, type Absolute(0). */
    uint128 internal constant TICK_ABSOLUTE = uint128(uint256(50_000e18) << 8);
    /* Ratio-limit tick: 5000 bps = 50% LTV, durIdx 0, rateIdx 0, type Ratio(1). */
    uint128 internal constant TICK_RATIO = uint128((uint256(5000) << 8) | 1);
    /* ILiquidity.InsufficientLiquidity() — the only revert the capacity bisection may treat
       as "boundary reached". Declared locally: ILiquidity lives in metastreet-contracts-v2. */
    bytes4 internal constant INSUFFICIENT_LIQUIDITY_SELECTOR = bytes4(keccak256("InsufficientLiquidity()"));
    uint24 internal constant CONFIDENCE_SCORE = 9000;
    uint64 internal constant CYCLE = 1;
    /* Large enough that Ratio capacity on the launch pool is oracle-bound, not
       deposit-bound. This keeps acceptance (a) from becoming oracle-inert. */
    uint256 internal constant LP_DEPOSIT = 60_000e6;
    /* Sized ABOVE both tick limits at both oracle prices (ratio limit is 44,000 then
       22,000 USDC; absolute limit is 50,000) so capacity is gated by the TICK, not by
       available liquidity. With a 10,000 deposit both ticks are liquidity-bound and
       the price coupling is invisible. */
    uint256 internal constant COUPLING_DEPOSIT = 60_000e6;
    /* The coupling fixture disables the temporal floor so the usable price is exactly the
       live MIN and the halving arithmetic is exact. Under the merged 24h window the price
       moves 80,000 -> 44,000 (45%, not 50%), which is why the exact-halving assertion is
       written against this fixture and the SHIPPED config is covered by the
       cross-multiplied proportionality assertion in the same test. */
    uint64 internal constant COUPLING_SEASONING_WINDOW = 0;
    uint256 internal constant PRINCIPAL = 1_000e6;

    FabricaAttributeOracle internal factStore;
    FabricaOracleAggregator internal aggregator;
    FabricaOracleAggregator internal couplingAggregator;
    address internal launchPool;

    address internal oracleOwner = makeAddr("eng3519-oracle-owner");
    address internal publisher = makeAddr("eng3519-price-publisher");
    address internal lp = makeAddr("eng3519-lp");

    function setUp() public {
        bool forked = _forkOrRequire(
            ForkConfig({
                rpcEnvVar: "SEPOLIA_RPC_URL",
                rpcAlias: "sepolia",
                blockNumber: FORK_BLOCK,
                requiredEnvVar: "FABRICA_REQUIRE_SEPOLIA_FV"
            })
        );
        if (!forked) return;
        assertEq(block.chainid, SEPOLIA_CHAIN_ID, "SEPOLIA_RPC_URL must target Sepolia");
        assertEq(
            IERC1155(FABRICA_TOKEN).balanceOf(COLLATERAL_HOLDER, COLLATERAL_TOKEN_ID),
            1,
            "fixture: holder must hold exactly 1 collateral unit at FORK_BLOCK"
        );
        _deployAndSeedFactStore();
        _deployAndRenounceAggregator();
        launchPool = _createLaunchPool(address(aggregator));
        _fundAndDeposit(launchPool);
    }

    /* =====================================================================
       Ticket item 1 — deployment mode of the EXISTING live pool.
       ===================================================================== */
    function test_item1_livePoolIsBeaconProxyNotClone() public view {
        address beaconFromSlot = address(uint160(uint256(vm.load(LIVE_POOL, ERC1967Utils.BEACON_SLOT))));
        assertEq(beaconFromSlot, BEACON, "live pool ERC-1967 beacon slot must hold the UpgradeableBeacon");
        assertEq(LIVE_POOL.code.length, LIVE_POOL_RUNTIME_BYTES, "BeaconProxy runtime, not a 45-byte EIP-1167 clone");
        address[] memory impls = IPoolFactoryLike(FACTORY).getPoolImplementations();
        assertEq(impls.length, 1, "factory allows exactly one implementation");
        assertEq(impls[0], BEACON, "the sole allowed implementation IS the beacon (the createProxied path)");
    }

    function test_item3_launchPoolIsBeaconProxyWiredToAggregator() public view {
        address beaconFromSlot = address(uint160(uint256(vm.load(launchPool, ERC1967Utils.BEACON_SLOT))));
        assertEq(beaconFromSlot, BEACON, "launch pool must be a BeaconProxy on the live beacon");
        assertEq(ILaunchPool(launchPool).priceOracle(), address(aggregator), "oracle wired at initialize()");
        assertEq(ILaunchPool(launchPool).currencyToken(), USDC, "currency");
        assertEq(ILaunchPool(launchPool).admin(), FACTORY, "admin is the factory");
        assertTrue(IPoolFactoryLike(FACTORY).isPool(launchPool), "registered in factory");
        assertTrue(aggregator.renounced(), "aggregator must be renounced before launch");
        /* Scopes every acceptance claim in this suite to the implementation it ran
           against. WP-B's 2.16 setPriceOracle is NOT deployed on Sepolia. */
        assertEq(ILaunchPool(launchPool).IMPLEMENTATION_VERSION(), "2.15", "rehearsal is bound to live 2.15");
    }

    /* The launch tiers are hand-copied from metastreet-contracts-v2's
       script/FabricaLendingPoolCreateWithAggregator.s.sol and cannot be imported across
       the repo boundary. Pin them against the live pool so the copy cannot drift silently. */
    function test_launchTiersMatchLivePool() public view {
        uint64[] memory liveDurations = ILaunchPool(LIVE_POOL).durations();
        uint64[] memory liveRates = ILaunchPool(LIVE_POOL).rates();
        assertEq(abi.encode(liveDurations), abi.encode(_launchDurations()), "durations drifted from the live pool");
        assertEq(abi.encode(liveRates), abi.encode(_launchRates()), "rates drifted from the live pool");
        assertEq(abi.encode(ILaunchPool(launchPool).durations()), abi.encode(liveDurations), "launch pool durations");
        assertEq(abi.encode(ILaunchPool(launchPool).rates()), abi.encode(liveRates), "launch pool rates");
    }

    /* Reads the aggregator's LIVE storage, not its pure documentation getter, so a
       constructor-argument transposition cannot pass. */
    function test_aggregatorUsesMergedDesignReviewDefaults() public view {
        assertEq(aggregator.seasoningWindow(), SEASONING_WINDOW, "seasoningWindow");
        assertEq(aggregator.maxJumpBps(), MAX_JUMP_BPS, "maxJumpBps");
        assertEq(aggregator.maxDispersionBps(), MAX_DISPERSION_BPS, "maxDispersionBps");
        assertEq(aggregator.minLiveSources(), MIN_LIVE_SOURCES, "minLiveSources");
        (uint64 seasoning, uint16 jump, uint16 dispersion, uint8 minLive,,) = aggregator.designReviewDefaults();
        assertEq(seasoning, SEASONING_WINDOW, "seasoningWindow drifted from merged default");
        assertEq(jump, MAX_JUMP_BPS, "maxJumpBps drifted from merged default");
        assertEq(dispersion, MAX_DISPERSION_BPS, "maxDispersionBps drifted from merged default");
        assertEq(minLive, MIN_LIVE_SOURCES, "minLiveSources drifted from merged default");
    }

    /* =====================================================================
       ACCEPTANCE (a) — the launch pool ORIGINATES A LOAN through the on-chain
       oracle with EMPTY oracleContext.
       ===================================================================== */
    function test_acceptanceA_originatesLoanWithEmptyOracleContext() public {
        uint256 oraclePrice = _assertLaunchOraclePrice();
        uint128[] memory ticks = _ticks(TICK_RATIO);
        uint256 ratioCapacityBefore = _assertLaunchRatioCapacityBefore(oraclePrice);
        uint256 absoluteCapacityBefore = _assertLaunchAbsoluteCapacity();
        uint256 repayment = _originateLaunchLoan(ticks);
        (uint256 oraclePriceAfter, uint256 ratioCapacityAfter, uint256 absoluteCapacityAfter) =
            _halveSourcesAndReadCapacities();
        _assertLaunchCapacitiesAfterHalving(
            oraclePriceAfter, ratioCapacityBefore, ratioCapacityAfter, absoluteCapacityBefore, absoluteCapacityAfter
        );
        _logAcceptanceA(
            repayment, ratioCapacityBefore, ratioCapacityAfter, absoluteCapacityBefore, absoluteCapacityAfter
        );
    }

    /* =====================================================================
       The coupling proof acceptance (a) cannot give. On a RATIO tick the
       borrowable depth is oraclePrice * bps / 10_000, so halving the oracle
       price must halve capacity. On an ABSOLUTE tick it must not move at all.
       ===================================================================== */
    function test_oraclePriceMovesRatioCapacityButNotAbsolute() public {
        /* Uses a SECOND aggregator with seasoningWindow = 0 so the temporal floor is out
           of the picture and the usable price is exactly the live MIN. That isolates the
           price -> capacity mechanism being proven here; the acceptance path above keeps
           the merged 24h window. Every other knob is the merged value. */
        address couplingPool = _deployCouplingFixture();
        uint256 basePrice =
            couplingAggregator.price(FABRICA_TOKEN, USDC, _singleton(COLLATERAL_TOKEN_ID), _singleton(1), "");
        assertEq(basePrice, EXPECTED_LIVE_MIN, "floor disabled: usable price is the live MIN");
        uint256 ratioBefore = _maxBorrowable(couplingPool, TICK_RATIO, COUPLING_DEPOSIT);
        uint256 absoluteBefore = _maxBorrowable(couplingPool, TICK_ABSOLUTE, COUPLING_DEPOSIT);
        /* Pin the ABSOLUTE values the report publishes, and pin the fixture invariant the
           whole proof rests on: both capacities must be TICK-bound, not deposit-bound.
           Without these, `assertEq(absoluteAfter, absoluteBefore)` is satisfied by 0 == 0
           and by cap-clamping, and the published 44,000 / 22,000 / 50,000 figures are
           backed only by console.log. */
        assertEq(ratioBefore, (basePrice * 5000) / 10_000, "ratio depth == oraclePrice * bps");
        assertEq(ratioBefore, 44_000e6, "published ratio capacity");
        assertEq(absoluteBefore, 50_000e6, "published absolute capacity == the tick's absolute limit");
        assertGt(ratioBefore, 0, "ratio tick must fund something before the price moves");
        assertGt(absoluteBefore, 0, "absolute tick must fund something before the price moves");
        assertLt(ratioBefore, COUPLING_DEPOSIT, "ratio capacity must be tick-bound, not deposit-bound");
        assertLt(absoluteBefore, COUPLING_DEPOSIT, "absolute capacity must be tick-bound, not deposit-bound");
        /* Halve each source against its own previous value: exactly maxDownBps, which
           _enforceBand permits (it reverts only on strictly-below). */
        vm.warp(block.timestamp + factStore.minWriteInterval() + 1);
        _writePrice(SOURCE_PRYCD, PRICE_PRYCD / 2);
        _writePrice(SOURCE_OPENAVM, PRICE_OPENAVM / 2);
        uint256 halvedPrice =
            couplingAggregator.price(FABRICA_TOKEN, USDC, _singleton(COLLATERAL_TOKEN_ID), _singleton(1), "");
        assertEq(halvedPrice, basePrice / 2, "usable oracle price halved");
        uint256 ratioAfter = _maxBorrowable(couplingPool, TICK_RATIO, COUPLING_DEPOSIT);
        uint256 absoluteAfter = _maxBorrowable(couplingPool, TICK_ABSOLUTE, COUPLING_DEPOSIT);
        /* THE COUPLING PROOF: Ratio depth tracks the oracle; Absolute depth does not.
           This is the assertion acceptance (a) cannot make, and it is also the
           executable form of the tick-policy recommendation in the ENG-3519 report. */
        assertEq(ratioAfter, ratioBefore / 2, "Ratio capacity scales with oracle price");
        assertEq(ratioAfter, (halvedPrice * 5000) / 10_000, "ratio depth still == oraclePrice * bps");
        assertEq(absoluteAfter, absoluteBefore, "Absolute capacity is price-independent");
        assertEq(absoluteAfter, 50_000e6, "absolute capacity unchanged in absolute terms");
        /* Cross-multiplied form, which holds under ANY seasoningWindow — including the
           merged 24h config this fixture disables. Under the launch config the price
           moves 80,000 -> 44,000 (the floor makes the first step sticky), so the exact
           halving above would not hold, but this proportionality does. */
        assertEq(ratioAfter * basePrice, ratioBefore * halvedPrice, "ratio depth is proportional to oracle price");
        console.log("coupling: oracle price   before/after =", basePrice, halvedPrice);
        console.log("coupling: RATIO capacity before/after =", ratioBefore, ratioAfter);
        console.log("coupling: ABS   capacity before/after =", absoluteBefore, absoluteAfter);
    }

    /* =====================================================================
       ACCEPTANCE (b) — a pool pointed at a DEAD-HEARTBEAT oracle REFUSES new
       borrows. Same aggregator; heartbeat aged past maxSilence.
       ===================================================================== */
    function test_acceptanceB_deadHeartbeatRefusesNewBorrows() public {
        assertTrue(factStore.isHeartbeatFresh(VALIDATOR_ID), "heartbeat fresh pre-warp");
        uint64 maxSilence = factStore.maxSilence();
        vm.warp(block.timestamp + maxSilence + 1);
        assertFalse(factStore.isHeartbeatFresh(VALIDATOR_ID), "heartbeat dead post-warp");
        bytes memory expectedRevert =
            abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, aggregator.CHECK_HEARTBEAT());
        uint256[] memory ids = _singleton(COLLATERAL_TOKEN_ID);
        uint256[] memory qtys = _singleton(1);
        vm.expectRevert(expectedRevert);
        aggregator.price(FABRICA_TOKEN, USDC, ids, qtys, "");
        /* And therefore the BORROW is refused — the acceptance as stated.
           maxRepayment is an in-range value so the oracle check is the only thing
           that can revert this call. */
        uint128[] memory ticks = _ticks(TICK_RATIO);
        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155(FABRICA_TOKEN).setApprovalForAll(launchPool, true);
        vm.expectRevert(expectedRevert);
        _borrowLaunchPool(ticks, PRINCIPAL * 2);
        vm.stopPrank();
        console.log("acceptance(b): borrow refused with CheckFailed(heartbeat); maxSilence =", maxSilence);
    }

    /* =====================================================================
       Helpers
       ===================================================================== */
    function _price() internal view returns (uint256) {
        return aggregator.price(FABRICA_TOKEN, USDC, _singleton(COLLATERAL_TOKEN_ID), _singleton(1), "");
    }

    function _assertLaunchOraclePrice() internal view returns (uint256 oraclePrice) {
        oraclePrice = _price();
        /* MIN of the live sources, floored by the seasoned observation. Both halves of
           WP-A's "MIN + temporal floor" rule are load-bearing in this fixture. */
        assertEq(oraclePrice, EXPECTED_USABLE_PRICE, "temporal floor over MIN of live sources");
        assertLt(EXPECTED_USABLE_PRICE, EXPECTED_LIVE_MIN, "fixture: the floor must actually bind");
        console.log("acceptance(a): aggregator.price with empty context =", oraclePrice);
    }

    function _assertLaunchRatioCapacityBefore(uint256 oraclePrice) internal view returns (uint256 ratioCapacityBefore) {
        ratioCapacityBefore = _maxBorrowable(launchPool, TICK_RATIO, LP_DEPOSIT);
        assertEq(
            ratioCapacityBefore, (oraclePrice * 5000) / 10_000, "acceptance(a): Ratio capacity must be oracle-priced"
        );
        assertEq(ratioCapacityBefore, 40_000e6, "acceptance(a): published ratio capacity at usable price");
        assertGt(ratioCapacityBefore, PRINCIPAL, "acceptance(a): principal fits inside oracle-priced Ratio cap");
        assertLt(ratioCapacityBefore, LP_DEPOSIT, "acceptance(a): capacity is oracle-bound, not deposit-bound");
    }

    function _assertLaunchAbsoluteCapacity() internal view returns (uint256 absoluteCapacity) {
        absoluteCapacity = _maxBorrowable(launchPool, TICK_ABSOLUTE, LP_DEPOSIT);
        assertEq(absoluteCapacity, 50_000e6, "acceptance(a): absolute capacity equals the tick limit");
        assertLt(absoluteCapacity, LP_DEPOSIT, "acceptance(a): absolute capacity is tick-bound, not deposit-bound");
    }

    function _originateLaunchLoan(uint128[] memory ticks) internal returns (uint256 repayment) {
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(COLLATERAL_HOLDER);
        /* maxRepayment must stay well inside uint256 — Pool.borrow applies _scale()
           (x1e12 for 6dp USDC) to it, so type(uint256).max overflows before any pool
           logic runs. Quote first, then bound the borrow by it. */
        uint256 quoted = _quoteLaunchPool(ticks, PRINCIPAL);
        console.log("acceptance(a): quoted repayment =", quoted);
        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155(FABRICA_TOKEN).setApprovalForAll(launchPool, true);
        vm.recordLogs();
        repayment = _borrowLaunchPool(ticks, quoted);
        vm.stopPrank();
        assertEq(repayment, quoted, "borrow repayment matches the quote");
        assertGt(repayment, PRINCIPAL, "repayment accrues interest over principal");
        assertEq(
            IERC20(USDC).balanceOf(COLLATERAL_HOLDER) - borrowerUsdcBefore, PRINCIPAL, "borrower received principal"
        );
        assertEq(IERC1155(FABRICA_TOKEN).balanceOf(COLLATERAL_HOLDER, COLLATERAL_TOKEN_ID), 0, "collateral escrowed");
        assertTrue(_sawLoanOriginated(vm.getRecordedLogs(), launchPool), "LoanOriginated emitted by the launch pool");
    }

    function _halveSourcesAndReadCapacities()
        internal
        returns (uint256 oraclePriceAfter, uint256 ratioCapacityAfter, uint256 absoluteCapacityAfter)
    {
        vm.warp(block.timestamp + factStore.minWriteInterval() + 1);
        _writePrice(SOURCE_PRYCD, PRICE_PRYCD / 2);
        _writePrice(SOURCE_OPENAVM, PRICE_OPENAVM / 2);
        oraclePriceAfter = _price();
        ratioCapacityAfter = _maxBorrowable(launchPool, TICK_RATIO, LP_DEPOSIT);
        absoluteCapacityAfter = _maxBorrowable(launchPool, TICK_ABSOLUTE, LP_DEPOSIT);
    }

    function _assertLaunchCapacitiesAfterHalving(
        uint256 oraclePriceAfter,
        uint256 ratioCapacityBefore,
        uint256 ratioCapacityAfter,
        uint256 absoluteCapacityBefore,
        uint256 absoluteCapacityAfter
    ) internal pure {
        assertEq(oraclePriceAfter, PRICE_OPENAVM / 2, "acceptance(a): oracle price moved after source halving");
        assertEq(
            ratioCapacityAfter,
            (oraclePriceAfter * 5000) / 10_000,
            "acceptance(a): Ratio capacity still tracks oracle price"
        );
        assertLt(ratioCapacityAfter, ratioCapacityBefore, "acceptance(a): lower oracle price reduces Ratio capacity");
        assertLt(ratioCapacityAfter, 30_000e6, "acceptance(a): mutation would reject a now-over-cap borrow");
        assertEq(absoluteCapacityAfter, absoluteCapacityBefore, "acceptance(a): absolute capacity ignores oracle price");
    }

    function _logAcceptanceA(
        uint256 repayment,
        uint256 ratioCapacityBefore,
        uint256 ratioCapacityAfter,
        uint256 absoluteCapacityBefore,
        uint256 absoluteCapacityAfter
    ) internal pure {
        console.log("acceptance(a): principal  =", PRINCIPAL);
        console.log("acceptance(a): repayment  =", repayment);
        console.log("acceptance(a): RATIO capacity before/after =", ratioCapacityBefore, ratioCapacityAfter);
        console.log("acceptance(a): ABS   capacity before/after =", absoluteCapacityBefore, absoluteCapacityAfter);
    }

    /* Largest principal `pool` will source from `tick`, found by bisection on quote().
       Capacity — not repayment — is what the oracle price actually controls, so this is
       the observable that must move with price on a Ratio tick. */
    function _maxBorrowable(address pool, uint128 tick, uint256 cap) internal view returns (uint256) {
        uint128[] memory ticks = _ticks(tick);
        uint256 lo = 0;
        uint256 hi = cap;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_quotable(pool, ticks, mid)) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        return lo;
    }

    function _quotable(address pool, uint128[] memory ticks, uint256 principal) internal view returns (bool) {
        try ILaunchPool(pool)
            .quote(principal, _borrowDuration(), FABRICA_TOKEN, COLLATERAL_TOKEN_ID, ticks, "") returns (
            uint256
        ) {
            return true;
        } catch (bytes memory err) {
            // forge-lint: disable-next-line(unsafe-typecast)
            if (err.length >= 4 && bytes4(err) == INSUFFICIENT_LIQUIDITY_SELECTOR) {
                return false;
            }
            revert("unexpected quote revert during capacity bisection");
        }
    }

    function _quoteLaunchPool(uint128[] memory ticks, uint256 principal) internal view returns (uint256) {
        return _quoteLaunchPoolFor(launchPool, COLLATERAL_TOKEN_ID, ticks, principal);
    }

    function _quoteLaunchPoolFor(address pool, uint256 tokenId, uint128[] memory ticks, uint256 principal)
        internal
        view
        returns (uint256)
    {
        return ILaunchPool(pool).quote(principal, _borrowDuration(), FABRICA_TOKEN, tokenId, ticks, "");
    }

    function _borrowLaunchPool(uint128[] memory ticks, uint256 maxRepayment) internal returns (uint256) {
        return _borrowLaunchPoolFor(launchPool, COLLATERAL_TOKEN_ID, ticks, PRINCIPAL, maxRepayment);
    }

    function _borrowLaunchPoolFor(
        address pool,
        uint256 tokenId,
        uint128[] memory ticks,
        uint256 principal,
        uint256 maxRepayment
    ) internal returns (uint256) {
        /* options = "" => BorrowLogic._getOptionsData(OracleContext) yields EMPTY bytes. */
        return ILaunchPool(pool)
            .borrow(COLLATERAL_HOLDER, principal, _borrowDuration(), FABRICA_TOKEN, tokenId, maxRepayment, ticks, "");
    }

    /* Second aggregator + pool with the temporal floor disabled, so the coupling test
       observes the live MIN directly. All other knobs are the merged values. */
    function _deployCouplingFixture() internal returns (address pool) {
        couplingAggregator = _deployRenouncedAggregator(COUPLING_SEASONING_WINDOW);
        assertEq(couplingAggregator.seasoningWindow(), 0, "coupling fixture disables the temporal floor");
        assertTrue(couplingAggregator.renounced(), "coupling aggregator renounced");
        pool = _createLaunchPool(address(couplingAggregator));
        assertEq(ILaunchPool(pool).priceOracle(), address(couplingAggregator), "coupling pool wired");
        _fundAndDepositAmount(pool, COUPLING_DEPOSIT);
    }

    function _deployAndSeedFactStore() internal {
        /* defaultKnobs() is `external pure`, so it needs an instance to call but its
           result does not depend on that instance's config. Deploy a throwaway with
           deliberately non-default bootstrap values, read the canonical defaults off it,
           then deploy the real store with those. This keeps ZERO hand-copied duplicate of
           the merged defaults in this file. (`historyDepth` is constructor-immutable and
           `setKnobs` does not cover it, so the defaults cannot be reconstructed
           post-deploy — hence the throwaway rather than a setter.) */
        FabricaAttributeOracle bootstrap = new FabricaAttributeOracle(oracleOwner, _bootstrapKnobs());
        factStore = new FabricaAttributeOracle(oracleOwner, bootstrap.defaultKnobs());
        vm.startPrank(oracleOwner);
        factStore.setPricePublisher(VALIDATOR_ID, publisher, true);
        /* register() also sets recovery status to RECOVERY_NORMAL. Sources 0-2 are
           already enabled by the constructor, so no setSourceEnabled call is needed. */
        factStore.register(VALIDATOR_ID, COLLATERAL_TOKEN_ID);
        vm.stopPrank();
        /* Clear registrySeasonDelay so isRegistrySeasoned() passes. */
        vm.warp(block.timestamp + factStore.registrySeasonDelay() + 1);
        /* Seed a seasoned observation first, then warp a full seasoning window so the
           temporal floor has something older than `now - seasoningWindow` to find. */
        _writePrice(SOURCE_PRYCD, PRICE_SEASONED_PRYCD);
        _writePrice(SOURCE_OPENAVM, PRICE_SEASONED_OPENAVM);
        vm.warp(block.timestamp + SEASONING_WINDOW + 1);
        _writePrice(SOURCE_PRYCD, PRICE_PRYCD);
        _writePrice(SOURCE_OPENAVM, PRICE_OPENAVM);
        assertTrue(factStore.isHeartbeatFresh(VALIDATOR_ID), "heartbeat seeded");
        assertTrue(factStore.isRegistrySeasoned(VALIDATOR_ID, COLLATERAL_TOKEN_ID), "registry seasoned");
        assertTrue(factStore.isRecoveryNormal(VALIDATOR_ID, COLLATERAL_TOKEN_ID), "recovery normal");
    }

    function _writePrice(uint8 sourceId, uint128 priceUsdc6) internal {
        _writePriceAt(factStore, COLLATERAL_TOKEN_ID, sourceId, priceUsdc6, CYCLE);
    }

    function _writePriceAt(
        FabricaAttributeOracle store,
        uint256 tokenId,
        uint8 sourceId,
        uint128 priceUsdc6,
        uint64 cycle
    ) internal {
        FabricaAttributeOracle.Provenance memory prov = FabricaAttributeOracle.Provenance({
            rawPayloadHash: keccak256(
                abi.encodePacked("fork-raw", address(store), tokenId, sourceId, priceUsdc6, cycle)
            ),
            inputsHash: keccak256(
                abi.encodePacked("fork-inputs", address(store), tokenId, sourceId, priceUsdc6, cycle)
            ),
            timestamp: uint64(block.timestamp),
            signer: publisher
        });
        FabricaAttributeOracle.PriceWriteParams memory params = FabricaAttributeOracle.PriceWriteParams({
            validatorId: VALIDATOR_ID,
            tokenId: tokenId,
            sourceId: sourceId,
            priceUsdc6: priceUsdc6,
            confidenceScore: CONFIDENCE_SCORE,
            valuedAt: uint64(block.timestamp),
            cycle: cycle,
            provenance: prov
        });
        vm.prank(publisher);
        store.writePrice(params);
    }

    function _deployAndRenounceAggregator() internal {
        /* Renounce BEFORE the pool points at it — the launch invariant. */
        aggregator = _deployRenouncedAggregator(SEASONING_WINDOW);
        assertTrue(aggregator.renounced(), "aggregator renounced");
        assertEq(aggregator.owner(), address(0), "renounce clears ownership");
    }

    /* Single construction site for the aggregator so the launch fixture and the coupling
       fixture cannot drift apart on the eight knobs they must share. */
    function _deployRenouncedAggregator(uint64 seasoningWindow) internal returns (FabricaOracleAggregator agg) {
        return _deployRenouncedAggregatorForStore(factStore, seasoningWindow);
    }

    function _deployRenouncedAggregatorForStore(FabricaAttributeOracle store, uint64 seasoningWindow)
        internal
        returns (FabricaOracleAggregator agg)
    {
        uint8[] memory sourceIds = new uint8[](2);
        sourceIds[0] = SOURCE_PRYCD;
        sourceIds[1] = SOURCE_OPENAVM;
        agg = new FabricaOracleAggregator(
            oracleOwner,
            address(store),
            USDC,
            VALIDATOR_ID,
            sourceIds,
            seasoningWindow,
            MAX_JUMP_BPS,
            MAX_DISPERSION_BPS,
            MIN_LIVE_SOURCES
        );
        vm.prank(oracleOwner);
        agg.renounceAggregator();
    }

    function _createLaunchPool(address priceOracle) internal returns (address) {
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = FABRICA_TOKEN;
        bytes memory params = abi.encode(collateralTokens, USDC, priceOracle, _launchDurations(), _launchRates());
        return IPoolFactoryLike(FACTORY).createProxied(BEACON, params);
    }

    function _fundAndDeposit(address pool) internal {
        _fundAndDepositAmount(pool, LP_DEPOSIT);
    }

    function _fundAndDepositAmount(address pool, uint256 amount) internal {
        deal(USDC, lp, amount * 2, true);
        vm.startPrank(lp);
        IERC20(USDC).approve(pool, amount * 2);
        ILaunchPool(pool).deposit(TICK_RATIO, amount, 0);
        ILaunchPool(pool).deposit(TICK_ABSOLUTE, amount, 0);
        vm.stopPrank();
    }

    function _sawLoanOriginated(Vm.Log[] memory logs, address pool) internal pure returns (bool) {
        (bool found,) = _loanOriginatedLogData(logs, pool);
        return found;
    }

    function _loanOriginatedLogData(Vm.Log[] memory logs, address pool)
        internal
        pure
        returns (bool found, bytes memory loanOriginatedEventData)
    {
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == pool && logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                return (true, logs[i].data);
            }
        }
        return (false, "");
    }

    function _ticks(uint128 tick) internal pure returns (uint128[] memory ticks) {
        ticks = new uint128[](1);
        ticks[0] = tick;
    }

    function _singleton(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    /* Deliberately NOT the merged defaults: only used to construct the throwaway
       instance whose `defaultKnobs()` supplies them. Values chosen to satisfy
       _validateKnobs and to look nothing like production. */
    function _bootstrapKnobs() internal pure returns (FabricaAttributeOracle.KnobConfig memory) {
        return FabricaAttributeOracle.KnobConfig({
            maxUpBps: 1,
            maxDownBps: 1,
            maxFirstPriceUsdc6: 1,
            maxSilence: 1,
            minWriteInterval: 0,
            registrySeasonDelay: 0,
            valueCeilingUsdc6: 1,
            historyDepth: 1
        });
    }

    /* The tick's durIdx — not this value — selects the rate tier: TICK_ABSOLUTE and
       TICK_RATIO both encode durIdx 0 / rateIdx 0, so rates[0] applies even though the
       borrow duration is the shortest tier. */
    function _borrowDuration() internal pure returns (uint64) {
        return _launchDurations()[7];
    }

    /* Launch durations/rates, verbatim from metastreet-contracts-v2's
       script/FabricaLendingPoolCreateWithAggregator.s.sol. Cross-repo, so they cannot
       be imported; test_launchTiersMatchLivePool pins them instead. */
    function _launchDurations() internal pure returns (uint64[] memory durations) {
        durations = new uint64[](8);
        durations[0] = 62208000;
        durations[1] = 31104000;
        durations[2] = 23328000;
        durations[3] = 15552000;
        durations[4] = 10368000;
        durations[5] = 7776000;
        durations[6] = 5184000;
        durations[7] = 2592000;
    }

    function _launchRates() internal pure returns (uint64[] memory rates) {
        rates = new uint64[](8);
        rates[0] = 1585489599;
        rates[1] = 2219685438;
        rates[2] = 3170979198;
        rates[3] = 4122272957;
        rates[4] = 4756468797;
        rates[5] = 5390664637;
        rates[6] = 6341958396;
        rates[7] = 7927447995;
    }
}
