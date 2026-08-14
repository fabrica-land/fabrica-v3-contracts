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
 * the borrow path and did not revert, nothing more. `test_oraclePriceMovesRatioCapacity`
 * is the test that actually binds price to dollars; the Absolute case is deliberately
 * kept alongside it to demonstrate the price-independence that ENG-3519's tick-policy
 * recommendation relies on.
 *
 * NO BROADCAST. Fork rehearsal only. Real-chain broadcasts on this stack are
 * Tim/Fede-gated — see `LENDING-POOL-RUNBOOK.md` § "ENG-3519 WP-B" in
 * metastreet-contracts-v2, and the NatSpec on that repo's
 * `script/FabricaLendingPoolCreateWithAggregator.s.sol`.
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
    uint128 internal constant PRICE_SEASONED = 80_000e6;
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
    uint256 internal constant LP_DEPOSIT = 10_000e6;
    /* Sized ABOVE both tick limits at both oracle prices (ratio limit is 44,000 then
       22,000 USDC; absolute limit is 50,000) so capacity is gated by the TICK, not by
       available liquidity. With a 10,000 deposit both ticks are liquidity-bound and
       the price coupling is invisible. */
    uint256 internal constant COUPLING_DEPOSIT = 60_000e6;
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
        uint256 oraclePrice = _price();
        /* MIN of the live sources, floored by the seasoned observation. Both halves of
           WP-A's "MIN + temporal floor" rule are load-bearing in this fixture. */
        assertEq(oraclePrice, EXPECTED_USABLE_PRICE, "temporal floor over MIN of live sources");
        assertLt(EXPECTED_USABLE_PRICE, EXPECTED_LIVE_MIN, "fixture: the floor must actually bind");
        console.log("acceptance(a): aggregator.price with empty context =", oraclePrice);
        uint128[] memory ticks = _ticks(TICK_ABSOLUTE);
        uint256 borrowerUsdcBefore = IERC20(USDC).balanceOf(COLLATERAL_HOLDER);
        /* maxRepayment must stay well inside uint256 — Pool.borrow applies _scale()
           (x1e12 for 6dp USDC) to it, so type(uint256).max overflows before any pool
           logic runs. Quote first, then bound the borrow by it. */
        uint256 quoted =
            ILaunchPool(launchPool).quote(PRINCIPAL, BORROW_DURATION(), FABRICA_TOKEN, COLLATERAL_TOKEN_ID, ticks, "");
        console.log("acceptance(a): quoted repayment =", quoted);
        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155(FABRICA_TOKEN).setApprovalForAll(launchPool, true);
        vm.recordLogs();
        /* options = "" => BorrowLogic._getOptionsData(OracleContext) yields EMPTY bytes. */
        uint256 repayment = ILaunchPool(launchPool)
            .borrow(
                COLLATERAL_HOLDER, PRINCIPAL, BORROW_DURATION(), FABRICA_TOKEN, COLLATERAL_TOKEN_ID, quoted, ticks, ""
            );
        vm.stopPrank();
        assertEq(repayment, quoted, "borrow repayment matches the quote");
        assertGt(repayment, PRINCIPAL, "repayment accrues interest over principal");
        assertEq(
            IERC20(USDC).balanceOf(COLLATERAL_HOLDER) - borrowerUsdcBefore, PRINCIPAL, "borrower received principal"
        );
        assertEq(IERC1155(FABRICA_TOKEN).balanceOf(COLLATERAL_HOLDER, COLLATERAL_TOKEN_ID), 0, "collateral escrowed");
        assertTrue(_sawLoanOriginated(vm.getRecordedLogs(), launchPool), "LoanOriginated emitted by the launch pool");
        console.log("acceptance(a): principal  =", PRINCIPAL);
        console.log("acceptance(a): repayment  =", repayment);
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
        assertGt(ratioBefore, 0, "ratio tick must fund something before the price moves");
        /* Halve each source against its own previous value: exactly maxDownBps, which
           _enforceBand permits (it reverts only on strictly-below). */
        vm.warp(block.timestamp + factStoreKnobs().minWriteInterval + 1);
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
        assertEq(absoluteAfter, absoluteBefore, "Absolute capacity is price-independent");
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
        uint64 maxSilence = factStore.defaultKnobs().maxSilence;
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
        uint128[] memory ticks = _ticks(TICK_ABSOLUTE);
        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155(FABRICA_TOKEN).setApprovalForAll(launchPool, true);
        vm.expectRevert(expectedRevert);
        ILaunchPool(launchPool)
            .borrow(
                COLLATERAL_HOLDER,
                PRINCIPAL,
                BORROW_DURATION(),
                FABRICA_TOKEN,
                COLLATERAL_TOKEN_ID,
                PRINCIPAL * 2,
                ticks,
                ""
            );
        vm.stopPrank();
        console.log("acceptance(b): borrow refused with CheckFailed(heartbeat); maxSilence =", maxSilence);
    }

    /* =====================================================================
       Helpers
       ===================================================================== */
    function _price() internal view returns (uint256) {
        return aggregator.price(FABRICA_TOKEN, USDC, _singleton(COLLATERAL_TOKEN_ID), _singleton(1), "");
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
            .quote(principal, BORROW_DURATION(), FABRICA_TOKEN, COLLATERAL_TOKEN_ID, ticks, "") returns (
            uint256
        ) {
            return true;
        } catch {
            return false;
        }
    }

    /* Second aggregator + pool with the temporal floor disabled (seasoningWindow = 0),
       so the coupling test observes live MIN directly. All other knobs are merged values. */
    function _deployCouplingFixture() internal returns (address pool) {
        uint8[] memory sourceIds = new uint8[](2);
        sourceIds[0] = SOURCE_PRYCD;
        sourceIds[1] = SOURCE_OPENAVM;
        couplingAggregator = new FabricaOracleAggregator(
            oracleOwner,
            address(factStore),
            USDC,
            VALIDATOR_ID,
            sourceIds,
            0,
            MAX_JUMP_BPS,
            MAX_DISPERSION_BPS,
            MIN_LIVE_SOURCES
        );
        vm.prank(oracleOwner);
        couplingAggregator.renounceAggregator();
        pool = _createLaunchPool(address(couplingAggregator));
        _fundAndDepositAmount(pool, COUPLING_DEPOSIT);
    }

    function _deployAndSeedFactStore() internal {
        /* defaultKnobs() is `external pure`, so it needs an instance to call but its
           result does not depend on that instance's config. Deploy a throwaway with
           deliberately non-default bootstrap values, read the canonical defaults off it,
           then deploy the real store with those. This keeps ZERO hand-copied duplicate
           of the merged defaults in this file (the sibling copy in
           FabricaAttributeOracle.t.sol has already drifted: historyDepth 8 vs 48). */
        FabricaAttributeOracle bootstrap = new FabricaAttributeOracle(oracleOwner, _bootstrapKnobs());
        factStore = new FabricaAttributeOracle(oracleOwner, bootstrap.defaultKnobs());
        vm.startPrank(oracleOwner);
        factStore.setPricePublisher(VALIDATOR_ID, publisher, true);
        /* register() also sets recovery status to RECOVERY_NORMAL. Sources 0-2 are
           already enabled by the constructor, so no setSourceEnabled call is needed. */
        factStore.register(VALIDATOR_ID, COLLATERAL_TOKEN_ID);
        vm.stopPrank();
        /* Clear registrySeasonDelay so isRegistrySeasoned() passes. */
        vm.warp(block.timestamp + factStoreKnobs().registrySeasonDelay + 1);
        /* Seed a seasoned observation first, then warp a full seasoning window so the
           temporal floor has something older than `now - seasoningWindow` to find. */
        _writePrice(SOURCE_PRYCD, PRICE_SEASONED);
        _writePrice(SOURCE_OPENAVM, PRICE_SEASONED);
        vm.warp(block.timestamp + SEASONING_WINDOW + 1);
        _writePrice(SOURCE_PRYCD, PRICE_PRYCD);
        _writePrice(SOURCE_OPENAVM, PRICE_OPENAVM);
        assertTrue(factStore.isHeartbeatFresh(VALIDATOR_ID), "heartbeat seeded");
        assertTrue(factStore.isRegistrySeasoned(VALIDATOR_ID, COLLATERAL_TOKEN_ID), "registry seasoned");
        assertTrue(factStore.isRecoveryNormal(VALIDATOR_ID, COLLATERAL_TOKEN_ID), "recovery normal");
    }

    function _writePrice(uint8 sourceId, uint128 priceUsdc6) internal {
        FabricaAttributeOracle.Provenance memory prov = FabricaAttributeOracle.Provenance({
            rawPayloadHash: keccak256(abi.encodePacked("eng3519-raw", sourceId, priceUsdc6)),
            inputsHash: keccak256(abi.encodePacked("eng3519-inputs", sourceId, priceUsdc6)),
            timestamp: uint64(block.timestamp),
            signer: publisher
        });
        FabricaAttributeOracle.PriceWriteParams memory params = FabricaAttributeOracle.PriceWriteParams({
            validatorId: VALIDATOR_ID,
            tokenId: COLLATERAL_TOKEN_ID,
            sourceId: sourceId,
            priceUsdc6: priceUsdc6,
            confidenceScore: CONFIDENCE_SCORE,
            valuedAt: uint64(block.timestamp),
            cycle: CYCLE,
            provenance: prov
        });
        vm.prank(publisher);
        factStore.writePrice(params);
    }

    function _deployAndRenounceAggregator() internal {
        uint8[] memory sourceIds = new uint8[](2);
        sourceIds[0] = SOURCE_PRYCD;
        sourceIds[1] = SOURCE_OPENAVM;
        aggregator = new FabricaOracleAggregator(
            oracleOwner,
            address(factStore),
            USDC,
            VALIDATOR_ID,
            sourceIds,
            SEASONING_WINDOW,
            MAX_JUMP_BPS,
            MAX_DISPERSION_BPS,
            MIN_LIVE_SOURCES
        );
        /* Renounce BEFORE the pool points at it — the launch invariant. */
        vm.prank(oracleOwner);
        aggregator.renounceAggregator();
        assertTrue(aggregator.renounced(), "aggregator renounced");
        assertEq(aggregator.owner(), address(0), "renounce clears ownership");
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
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == pool && logs[i].topics.length > 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _ticks(uint128 tick) internal pure returns (uint128[] memory ticks) {
        ticks = new uint128[](1);
        ticks[0] = tick;
    }

    function _singleton(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    /* The merged defaults, read off the deployed store — never mirrored locally. */
    function factStoreKnobs() internal view returns (FabricaAttributeOracle.KnobConfig memory) {
        return factStore.defaultKnobs();
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
    function BORROW_DURATION() internal pure returns (uint64) {
        return _launchDurations()[7];
    }

    uint24 internal constant CONFIDENCE_SCORE = 9000;
    uint64 internal constant CYCLE = 1;

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
