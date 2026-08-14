// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {FabricaAttributeOracle} from "../src/FabricaAttributeOracle.sol";
import {FabricaOracleAggregator} from "../src/FabricaOracleAggregator.sol";
import {IFabricaAttributeOracle} from "../src/interfaces/IFabricaAttributeOracle.sol";

/**
 * ENG-3519 — Sepolia launch-pool acceptance REHEARSAL, on a Sepolia fork.
 *
 * WHY THIS EXISTS (and how it differs from WP-B's suite):
 * metastreet-contracts-v2's FabricaLendingPoolOracleTimelock.t.sol proves the
 * WP-B wiring against a `MockAggregatorOracle` stub and asserts at the
 * `pool.price(...)` level. It never deploys the real aggregator, never touches
 * the live beacon, and never originates a loan. The ticket's acceptance is
 * stated at the BORROW level ("ORIGINATES A LOAN", "REFUSES NEW BORROWS"), so
 * this suite closes that gap:
 *
 *   - real FabricaOracleAggregator (WP-A), post-`renounceAggregator()`
 *   - real FabricaAttributeOracle (ENG-3518) fact store, really seeded
 *   - the LIVE Sepolia PoolFactory + UpgradeableBeacon, so the pool is a real
 *     BeaconProxy dispatching into the deployed implementation bytecode
 *   - real `borrow()` origination with EMPTY `oracleContext`
 *   - real dead-heartbeat borrow REFUSAL
 *
 * NO BROADCAST. This is a fork rehearsal only. Real-chain broadcasts on this
 * stack are Tim/Fede-gated (LENDING-POOL-RUNBOOK.md § WP-B item 3, and the
 * NatSpec on FabricaLendingPoolCreateWithAggregator.s.sol).
 *
 * Run:
 *   forge test --match-contract Eng3519LaunchPoolSepoliaForkTest \
 *              --fork-url $SEPOLIA_RPC_URL -vv
 *
 * Without --fork-url every test short-circuits via `onlyFork`, mirroring the
 * repo's fork-test skip convention so a plain `forge test` stays green.
 */
interface IPoolFactoryLike {
    function createProxied(address poolBeacon, bytes calldata params) external returns (address);
    function getPoolImplementations() external view returns (address[] memory);
    function isPool(address pool) external view returns (bool);
}

interface ILaunchPool {
    function priceOracle() external view returns (address);
    function admin() external view returns (address);
    function currencyToken() external view returns (address);
    function collateralToken() external view returns (address);
    function IMPLEMENTATION_VERSION() external view returns (string memory);
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

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IERC1155Like {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
}

contract Eng3519LaunchPoolSepoliaForkTest is Test {
    /* ---------------------------------------------------------------------
       Live Sepolia stack (LENDING-POOL-RUNBOOK.md § Network Addresses).
       --------------------------------------------------------------------- */
    address internal constant FACTORY = 0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83;
    address internal constant BEACON = 0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e;
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant FABRICA_TOKEN = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    /* ERC-1967 beacon slot: keccak256("eip1967.proxy.beacon") - 1. */
    bytes32 internal constant ERC1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    /* A real FabricaToken holder + id on Sepolia (TransferSingle @ block 11293457). */
    address internal constant COLLATERAL_HOLDER = 0xe962D614fC0d3E9D3AD0a60301Cb0BA314b72a19;
    uint256 internal constant COLLATERAL_TOKEN_ID = 3561233430243998108;

    /* ---------------------------------------------------------------------
       Aggregator config — MERGED start proposals, read back from
       FabricaOracleAggregator.designReviewDefaults(). Not chosen here:
       maxJumpBps / maxDispersionBps are still "TBD" in the WP-A design-review
       table pending Tim/Fede sign-off. Asserted below so this rehearsal
       provably uses the merged values and nothing invented.
       --------------------------------------------------------------------- */
    uint64 internal constant SEASONING_WINDOW = 24 hours;
    uint16 internal constant MAX_JUMP_BPS = 5000;
    uint16 internal constant MAX_DISPERSION_BPS = 20_000;
    uint8 internal constant MIN_LIVE_SOURCES = 2;

    uint256 internal constant VALIDATOR_ID = 1;
    /* Two independent live sources — the aggregator's MIN input set. */
    uint8 internal constant SOURCE_PRYCD = 0;
    uint8 internal constant SOURCE_OPENAVM = 1;
    /* Per-source USDC(6dp) unit prices. MIN => 90_000e6 is the usable price. */
    uint128 internal constant PRICE_PRYCD = 90_000e6;
    uint128 internal constant PRICE_OPENAVM = 100_000e6;
    uint128 internal constant EXPECTED_MIN_PRICE = 90_000e6;

    /* Absolute-limit tick: limit = 50_000e18, durIdx 0, rateIdx 0, type Absolute(0).
       Absolute is the tick class WP-C recommends for land collateral. */
    uint128 internal constant TICK_ABSOLUTE = uint128(uint256(50_000 ether) << 8);
    uint64 internal constant BORROW_DURATION = 2592000;
    uint256 internal constant LP_DEPOSIT = 10_000e6;
    uint256 internal constant PRINCIPAL = 1_000e6;

    FabricaAttributeOracle internal factStore;
    FabricaOracleAggregator internal aggregator;
    address internal launchPool;

    address internal oracleOwner = makeAddr("eng3519-oracle-owner");
    address internal publisher = makeAddr("eng3519-price-publisher");
    address internal lp = makeAddr("eng3519-lp");

    /* Skip everything when no fork is supplied. */
    modifier onlyFork() {
        if (block.chainid != SEPOLIA_CHAIN_ID) return;
        _;
    }

    function setUp() public {
        if (block.chainid != SEPOLIA_CHAIN_ID) return;
        _deployAndSeedFactStore();
        _deployAndRenounceAggregator();
        launchPool = _createLaunchPool(address(aggregator));
        _fundAndDeposit(launchPool);
    }

    /* =====================================================================
       Ticket item 1 — deployment mode of the EXISTING live pool.
       ===================================================================== */
    function test_item1_livePoolIsBeaconProxyNotClone() public view onlyFork {
        address livePool = 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B;
        address beaconFromSlot = address(uint160(uint256(vm.load(livePool, ERC1967_BEACON_SLOT))));
        assertEq(beaconFromSlot, BEACON, "live pool ERC-1967 beacon slot must hold the UpgradeableBeacon");
        /* An EIP-1167 clone is exactly 45 bytes of runtime. A BeaconProxy is not. */
        assertGt(livePool.code.length, 45, "BeaconProxy runtime is larger than a 45-byte EIP-1167 clone");
        console.log("item 1: live pool runtime bytes =", livePool.code.length);
        console.log("item 1: beacon from ERC-1967 slot =", beaconFromSlot);
    }

    /* The pool this ticket would launch is created the same way. */
    function test_item3_launchPoolIsBeaconProxyWiredToAggregator() public view onlyFork {
        address beaconFromSlot = address(uint160(uint256(vm.load(launchPool, ERC1967_BEACON_SLOT))));
        assertEq(beaconFromSlot, BEACON, "launch pool must be a BeaconProxy on the live beacon");
        assertEq(ILaunchPool(launchPool).priceOracle(), address(aggregator), "oracle wired at initialize()");
        assertEq(ILaunchPool(launchPool).currencyToken(), USDC, "currency");
        assertEq(ILaunchPool(launchPool).admin(), FACTORY, "admin is the factory");
        assertTrue(IPoolFactoryLike(FACTORY).isPool(launchPool), "registered in factory");
        assertTrue(aggregator.renounced(), "aggregator must be renounced before launch");
        console.log("item 3: launch pool  =", launchPool);
        console.log("item 3: priceOracle  =", ILaunchPool(launchPool).priceOracle());
        console.log("item 3: impl version =", ILaunchPool(launchPool).IMPLEMENTATION_VERSION());
    }

    /* Guards the constants above against drift from the merged WP-A values. */
    function test_aggregatorUsesMergedDesignReviewDefaults() public view onlyFork {
        (uint64 seasoning, uint16 jump, uint16 dispersion, uint8 minLive,,) = aggregator.designReviewDefaults();
        assertEq(seasoning, SEASONING_WINDOW, "seasoningWindow drifted from merged default");
        assertEq(jump, MAX_JUMP_BPS, "maxJumpBps drifted from merged default");
        assertEq(dispersion, MAX_DISPERSION_BPS, "maxDispersionBps drifted from merged default");
        assertEq(minLive, MIN_LIVE_SOURCES, "minLiveSources drifted from merged default");
    }

    /* =====================================================================
       ACCEPTANCE (a) — the launch pool ORIGINATES A LOAN priced by the
       on-chain oracle, with EMPTY oracleContext.
       ===================================================================== */
    function test_acceptanceA_originatesLoanWithEmptyOracleContext() public onlyFork {
        /* The aggregator prices off on-chain facts alone — empty context. */
        uint256[] memory ids = new uint256[](1);
        uint256[] memory qtys = new uint256[](1);
        ids[0] = COLLATERAL_TOKEN_ID;
        qtys[0] = 1;
        uint256 oraclePrice = aggregator.price(FABRICA_TOKEN, USDC, ids, qtys, "");
        assertEq(oraclePrice, EXPECTED_MIN_PRICE, "MIN of live sources is the usable price");
        console.log("acceptance(a): aggregator.price with empty context =", oraclePrice);

        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK_ABSOLUTE;
        uint256 borrowerUsdcBefore = IERC20Like(USDC).balanceOf(COLLATERAL_HOLDER);

        /* Quote first, then bound the borrow by it. maxRepayment must stay well
           inside uint256 — Pool.borrow applies _scale() (x1e12 for 6dp USDC) to
           it, so type(uint256).max here overflows before any pool logic runs. */
        uint256 quoted =
            ILaunchPool(launchPool).quote(PRINCIPAL, BORROW_DURATION, FABRICA_TOKEN, COLLATERAL_TOKEN_ID, ticks, "");
        console.log("acceptance(a): quoted repayment =", quoted);

        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155Like(FABRICA_TOKEN).setApprovalForAll(launchPool, true);
        vm.recordLogs();
        /* options = "" => BorrowLogic._getOptionsData(OracleContext) yields EMPTY bytes. */
        uint256 repayment = ILaunchPool(launchPool)
            .borrow(
                COLLATERAL_HOLDER, PRINCIPAL, BORROW_DURATION, FABRICA_TOKEN, COLLATERAL_TOKEN_ID, quoted, ticks, ""
            );
        vm.stopPrank();
        assertEq(repayment, quoted, "borrow repayment matches the oracle-priced quote");

        assertGt(repayment, PRINCIPAL, "repayment accrues interest over principal");
        assertEq(
            IERC20Like(USDC).balanceOf(COLLATERAL_HOLDER) - borrowerUsdcBefore,
            PRINCIPAL,
            "borrower received principal in USDC"
        );
        assertEq(
            IERC1155Like(FABRICA_TOKEN).balanceOf(COLLATERAL_HOLDER, COLLATERAL_TOKEN_ID),
            0,
            "collateral moved out of the borrower"
        );
        assertTrue(_sawLoanOriginated(vm.getRecordedLogs(), launchPool), "LoanOriginated emitted by the launch pool");
        console.log("acceptance(a): principal  =", PRINCIPAL);
        console.log("acceptance(a): repayment  =", repayment);
    }

    /* =====================================================================
       ACCEPTANCE (b) — a pool pointed at a DEAD-HEARTBEAT oracle REFUSES
       new borrows. Same aggregator; heartbeat aged past maxSilence.
       ===================================================================== */
    function test_acceptanceB_deadHeartbeatRefusesNewBorrows() public onlyFork {
        /* Sanity: alive immediately before. */
        assertTrue(factStore.isHeartbeatFresh(VALIDATOR_ID), "heartbeat fresh pre-warp");

        (,,, uint64 maxSilence,,,,) = _knobs();
        vm.warp(block.timestamp + maxSilence + 1);
        assertFalse(factStore.isHeartbeatFresh(VALIDATOR_ID), "heartbeat dead post-warp");

        /* The oracle itself now fails closed with the HEARTBEAT check id. */
        uint256[] memory ids = new uint256[](1);
        uint256[] memory qtys = new uint256[](1);
        ids[0] = COLLATERAL_TOKEN_ID;
        qtys[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, aggregator.CHECK_HEARTBEAT())
        );
        aggregator.price(FABRICA_TOKEN, USDC, ids, qtys, "");

        /* And therefore the BORROW is refused — the acceptance as stated. */
        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK_ABSOLUTE;
        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155Like(FABRICA_TOKEN).setApprovalForAll(launchPool, true);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, aggregator.CHECK_HEARTBEAT())
        );
        /* maxRepayment is a plain in-range value so the ONLY thing that can
           revert this borrow is the oracle's fail-closed heartbeat check. */
        ILaunchPool(launchPool)
            .borrow(
                COLLATERAL_HOLDER,
                PRINCIPAL,
                BORROW_DURATION,
                FABRICA_TOKEN,
                COLLATERAL_TOKEN_ID,
                PRINCIPAL * 2,
                ticks,
                ""
            );
        vm.stopPrank();
        console.log("acceptance(b): borrow refused with CheckFailed(heartbeat) after maxSilence =", maxSilence);
    }

    /* =====================================================================
       Helpers
       ===================================================================== */
    function _deployAndSeedFactStore() internal {
        FabricaAttributeOracle store = new FabricaAttributeOracle(oracleOwner, _defaultKnobsFor());
        factStore = store;
        vm.startPrank(oracleOwner);
        store.setPricePublisher(VALIDATOR_ID, publisher, true);
        store.setSourceEnabled(SOURCE_PRYCD, true);
        store.setSourceEnabled(SOURCE_OPENAVM, true);
        /* register() also sets recovery status to RECOVERY_NORMAL. */
        store.register(VALIDATOR_ID, COLLATERAL_TOKEN_ID);
        vm.stopPrank();
        /* Clear registrySeasonDelay so isRegistrySeasoned() passes. */
        (,,,,, uint64 seasonDelay,,) = _knobs();
        vm.warp(block.timestamp + seasonDelay + 1);
        /* Seed two live sources. Each write also touches the validator heartbeat. */
        _writePrice(SOURCE_PRYCD, PRICE_PRYCD);
        _writePrice(SOURCE_OPENAVM, PRICE_OPENAVM);
        assertTrue(store.isHeartbeatFresh(VALIDATOR_ID), "heartbeat seeded");
        assertTrue(store.isRegistrySeasoned(VALIDATOR_ID, COLLATERAL_TOKEN_ID), "registry seasoned");
        assertTrue(store.isRecoveryNormal(VALIDATOR_ID, COLLATERAL_TOKEN_ID), "recovery normal");
    }

    function _writePrice(uint8 sourceId, uint128 priceUsdc6) internal {
        FabricaAttributeOracle.Provenance memory prov = FabricaAttributeOracle.Provenance({
            rawPayloadHash: keccak256(abi.encodePacked("eng3519-raw", sourceId)),
            inputsHash: keccak256(abi.encodePacked("eng3519-inputs", sourceId)),
            timestamp: uint64(block.timestamp),
            signer: publisher
        });
        FabricaAttributeOracle.PriceWriteParams memory params = FabricaAttributeOracle.PriceWriteParams({
            validatorId: VALIDATOR_ID,
            tokenId: COLLATERAL_TOKEN_ID,
            sourceId: sourceId,
            priceUsdc6: priceUsdc6,
            confidenceScore: 9000,
            valuedAt: uint64(block.timestamp),
            cycle: 1,
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
    }

    function _createLaunchPool(address priceOracle) internal returns (address) {
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = FABRICA_TOKEN;
        bytes memory params = abi.encode(collateralTokens, USDC, priceOracle, _launchDurations(), _launchRates());
        return IPoolFactoryLike(FACTORY).createProxied(BEACON, params);
    }

    function _fundAndDeposit(address pool) internal {
        deal(USDC, lp, LP_DEPOSIT);
        vm.startPrank(lp);
        IERC20Like(USDC).approve(pool, LP_DEPOSIT);
        ILaunchPool(pool).deposit(TICK_ABSOLUTE, LP_DEPOSIT, 0);
        vm.stopPrank();
    }

    function _sawLoanOriginated(Vm.Log[] memory logs, address pool) internal pure returns (bool) {
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == pool && logs[i].topics.length > 0 && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    function _knobs()
        internal
        view
        returns (
            uint16 maxUpBps,
            uint16 maxDownBps,
            uint128 maxFirstPriceUsdc6,
            uint64 maxSilence,
            uint64 minWriteInterval,
            uint64 registrySeasonDelay,
            uint128 valueCeilingUsdc6,
            uint8 historyDepth
        )
    {
        FabricaAttributeOracle.KnobConfig memory k = _defaultKnobsFor();
        return (
            k.maxUpBps,
            k.maxDownBps,
            k.maxFirstPriceUsdc6,
            k.maxSilence,
            k.minWriteInterval,
            k.registrySeasonDelay,
            k.valueCeilingUsdc6,
            k.historyDepth
        );
    }

    /* Mirrors FabricaAttributeOracle.defaultKnobs(); asserted equal in setUp path. */
    function _defaultKnobsFor() internal pure returns (FabricaAttributeOracle.KnobConfig memory) {
        return FabricaAttributeOracle.KnobConfig({
            maxUpBps: 1500,
            maxDownBps: 5000,
            maxFirstPriceUsdc6: 50_000_000e6,
            maxSilence: 24 hours,
            minWriteInterval: 1 hours,
            registrySeasonDelay: 1 days,
            valueCeilingUsdc6: 50_000_000e6,
            historyDepth: 48
        });
    }

    /* Launch durations/rates verbatim from FabricaLendingPoolCreateWithAggregator.s.sol. */
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
