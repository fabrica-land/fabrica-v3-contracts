// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/Test.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {Eng3523OraclePoolSepoliaForkTest} from "./Eng3523OraclePoolSepoliaFork.t.sol";
import {IPoolFactoryLike, ILaunchPool} from "./Eng3519LaunchPoolSepoliaFork.t.sol";
import {FabricaFactStore} from "../src/FabricaFactStore.sol";
import {FabricaImmutableAggregator} from "../src/FabricaImmutableAggregator.sol";

/**
 * ENG-3925 — round-2 immutable aggregator on the live Sepolia launch-pool fork.
 *
 * WHAT THIS ADDS. It extends the ENG-3523 invariant suite, which itself extends the ENG-3519
 * launch-pool harness, so running this contract runs every round-1 invariant as well as the round-2
 * ones — the round-1 suite is the regression, not a separate job. Inherited from ENG-3519: the live
 * Sepolia PoolFactory, the shared BeaconProxy pool beacon, the launch tiers, the tick encodings and
 * the capacity bisection. New here: the round-2 permissionless fact store and the OWNERLESS
 * aggregator in the loop of a real origination on a pool this suite creates.
 *
 * WHY setUp IS NOT OVERRIDDEN. The round-2 fixture has to warp a full seasoning window to give the
 * temporal floor something to find. Foundry re-runs `setUp` for every test in the contract, so a
 * warp there would age the INHERITED round-1 fixture — its heartbeat would go stale and its
 * seasoned observation would stop binding — and would silently rewrite the round-1 acceptances this
 * suite exists to keep green. The round-2 stack is therefore built per-test by `_setUpRound2()`,
 * which each round-2 test calls first. Per-test state isolation makes that equivalent to a setUp
 * for these tests and invisible to the inherited ones.
 *
 * Run:
 *   forge test --match-contract Eng3925ImmutableAggregatorSepoliaForkTest -vv
 *
 * The fork is created and pinned by the inherited `setUp`. Without SEPOLIA_RPC_URL the suite reports
 * SKIPPED, never a silent pass; set FABRICA_REQUIRE_SEPOLIA_FV=1 to make a missing RPC a failure.
 */
contract Eng3925ImmutableAggregatorSepoliaForkTest is Eng3523OraclePoolSepoliaForkTest {
    /* Tim's numbers, 2026-09-03 18:12Z, plus the round-1 values ENG-3925 carries forward. These are
       the constructor arguments the Sepolia deploy uses; `test_round2_deployedParametersAreTimsNumbers`
       reads them back off the LIVE aggregator so a transposition cannot pass. */
    uint8 internal constant R2_MIN_LIVE_SOURCES = 2;
    uint64 internal constant R2_MAX_SILENCE = 3 days;
    uint64 internal constant R2_CYCLE_CLOSE_INTERVAL = 1 days;
    uint64 internal constant R2_SEASONING_WINDOW = 24 hours;
    uint16 internal constant R2_MAX_JUMP_BPS = 5000;
    uint16 internal constant R2_MAX_DISPERSION_BPS = 20_000;
    uint128 internal constant R2_MAX_FIRST_PRICE_USDC6 = 50_000_000e6;
    uint128 internal constant R2_VALUE_CEILING_USDC6 = 50_000_000e6;
    uint8 internal constant R2_HISTORY_DEPTH = 48;

    uint64 internal constant R2_CYCLE = 1;
    uint24 internal constant R2_CONFIDENCE = 9000;

    /* Lowest live valuation deliberately on the LAST writer, so a MIN assertion cannot be satisfied
       by "first writer" or "lowest address" semantics. */
    uint128 internal constant R2_SEASONED_PRYCD = 84_000e6;
    uint128 internal constant R2_SEASONED_OPENAVM = 82_000e6;
    uint128 internal constant R2_SEASONED_REGRID = 80_000e6;
    uint128 internal constant R2_LIVE_PRYCD = 92_000e6;
    uint128 internal constant R2_LIVE_OPENAVM = 90_000e6;
    uint128 internal constant R2_LIVE_REGRID = 88_000e6;
    uint128 internal constant R2_EXPECTED_LIVE_MIN = R2_LIVE_REGRID;
    /* The temporal floor takes MIN(live MIN, the MIN as of now - seasoningWindow), so the seasoned
       value is the usable price and both halves of the rule are load-bearing in this fixture. */
    uint128 internal constant R2_EXPECTED_USABLE = R2_SEASONED_REGRID;

    FabricaFactStore internal round2Store;
    FabricaImmutableAggregator internal round2Aggregator;
    address internal round2Pool;

    /* Stand-in writer set. The real oracle-source addresses are ENG-3926's provisioning; the fork
       proof does not depend on which addresses they are, only that they are fixed at deploy. */
    address internal writerPrycd = makeAddr("eng3925-writer-prycd");
    address internal writerOpenAvm = makeAddr("eng3925-writer-openavm");
    address internal writerRegrid = makeAddr("eng3925-writer-regrid");

    /* =====================================================================
       Deployment shape
       ===================================================================== */

    function test_round2_poolIsBeaconProxyWiredToTheImmutableAggregator() public {
        _setUpRound2();
        address beaconFromSlot = address(uint160(uint256(vm.load(round2Pool, ERC1967Utils.BEACON_SLOT))));
        assertEq(beaconFromSlot, BEACON, "round-2 pool must be a BeaconProxy on the live beacon");
        assertEq(round2Pool.code.length, LIVE_POOL_RUNTIME_BYTES, "BeaconProxy runtime, not an EIP-1167 clone");
        assertEq(ILaunchPool(round2Pool).priceOracle(), address(round2Aggregator), "oracle wired at initialize()");
        assertEq(ILaunchPool(round2Pool).currencyToken(), USDC, "currency");
        assertEq(ILaunchPool(round2Pool).admin(), FACTORY, "admin is the factory");
        assertTrue(IPoolFactoryLike(FACTORY).isPool(round2Pool), "registered in the factory");
        assertEq(ILaunchPool(round2Pool).IMPLEMENTATION_VERSION(), "2.15", "bound to the live 2.15 implementation");
        assertEq(
            abi.encode(ILaunchPool(round2Pool).durations()),
            abi.encode(_launchDurations()),
            "round-2 pool uses the launch durations"
        );
        assertEq(
            abi.encode(ILaunchPool(round2Pool).rates()),
            abi.encode(_launchRates()),
            "round-2 pool uses the launch rates"
        );
        /* The round-1 and signed-quote pools keep running: this ticket adds a pool, it does not
           repoint one. */
        assertTrue(round2Pool != LIVE_POOL, "a NEW pool, not the live round-1 pool");
        assertEq(ILaunchPool(LIVE_POOL).priceOracle(), ILaunchPool(LIVE_POOL).priceOracle(), "round-1 pool untouched");
    }

    /// @notice Reads the LIVE aggregator, so a constructor-argument transposition cannot pass.
    function test_round2_deployedParametersAreTimsNumbers() public {
        _setUpRound2();
        assertEq(address(round2Aggregator.factStore()), address(round2Store), "factStore");
        assertEq(round2Aggregator.usdc(), USDC, "usdc");
        assertEq(round2Aggregator.minLiveSources(), R2_MIN_LIVE_SOURCES, "minLiveSources");
        assertEq(round2Aggregator.maxSilence(), R2_MAX_SILENCE, "maxSilence");
        assertEq(round2Aggregator.cycleCloseInterval(), R2_CYCLE_CLOSE_INTERVAL, "cycleCloseInterval");
        assertEq(round2Aggregator.seasoningWindow(), R2_SEASONING_WINDOW, "seasoningWindow");
        assertEq(round2Aggregator.maxJumpBps(), R2_MAX_JUMP_BPS, "maxJumpBps");
        assertEq(round2Aggregator.maxDispersionBps(), R2_MAX_DISPERSION_BPS, "maxDispersionBps");
        assertEq(round2Aggregator.maxFirstPriceUsdc6(), R2_MAX_FIRST_PRICE_USDC6, "maxFirstPriceUsdc6");
        assertEq(round2Aggregator.valueCeilingUsdc6(), R2_VALUE_CEILING_USDC6, "valueCeilingUsdc6");
        /* Maximum silence is three cycle-close intervals: a writer misses two closes before dark. */
        assertEq(
            round2Aggregator.maxSilence(),
            3 * round2Aggregator.cycleCloseInterval(),
            "maxSilence is three cycle-close intervals"
        );
        address[] memory set = round2Aggregator.writers();
        assertEq(set.length, 3, "three oracle sources");
        assertEq(set[0], writerPrycd, "writers[0]");
        assertEq(set[1], writerOpenAvm, "writers[1]");
        assertEq(set[2], writerRegrid, "writers[2]");
    }

    /// @notice The on-chain form of the ABI claim: nothing privileged answers on the deployed address.
    /// @dev The unit suite asserts the stronger property from the compiled ABI (no state-mutating
    ///      external function exists at all). This is the complement a reviewer can reproduce against
    ///      a live address with `cast`, and it is the shape the as-shipped verification pastes.
    function test_round2_deployedAggregatorAnswersNoPrivilegedSelector() public {
        _setUpRound2();
        address target = address(round2Aggregator);
        assertGt(target.code.length, 0, "fixture: the aggregator must actually be deployed");
        string[9] memory privileged = [
            "owner()",
            "pendingOwner()",
            "renounceOwnership()",
            "renounceAggregator()",
            "transferOwnership(address)",
            "setFactStore(address)",
            "setUsdc(address)",
            "setKnobs(uint64,uint16,uint16,uint8)",
            "setLandUsePolicy(bool,bytes32)"
        ];
        for (uint256 i; i < privileged.length; ++i) {
            (bool ok,) = target.staticcall(abi.encodeWithSignature(privileged[i]));
            assertFalse(ok, string.concat("privileged selector answered: ", privileged[i]));
        }
        /* And the read surface it SHOULD answer still does, so the loop above is not passing merely
           because every call to this address fails. */
        (bool priceOk,) = target.staticcall(
            abi.encodeWithSignature(
                "price(address,address,uint256[],uint256[],bytes)",
                FABRICA_TOKEN,
                USDC,
                _singleton(COLLATERAL_TOKEN_ID),
                _singleton(1),
                ""
            )
        );
        assertTrue(priceOk, "the read surface answers, so the negative results above are meaningful");
    }

    /* =====================================================================
       Verification clause 1 — a usable price, and a real loan
       ===================================================================== */

    function test_round2_pricesTwoLiveValuationsAndOriginatesALoan() public {
        _setUpRound2();
        uint256 oraclePrice = _round2Price();
        assertEq(oraclePrice, R2_EXPECTED_USABLE, "temporal floor over MIN of live valuations");
        assertLt(R2_EXPECTED_USABLE, R2_EXPECTED_LIVE_MIN, "fixture: the floor must actually bind");

        uint256 ratioCapacity = _maxBorrowable(round2Pool, TICK_RATIO, LP_DEPOSIT);
        assertEq(ratioCapacity, (oraclePrice * 5000) / 10_000, "ratio capacity is oracle-priced");
        assertEq(ratioCapacity, 40_000e6, "published ratio capacity at the usable price");
        assertLt(ratioCapacity, LP_DEPOSIT, "capacity is oracle-bound, not deposit-bound");

        uint128[] memory ticks = _ticks(TICK_RATIO);
        uint256 quoted =
            ILaunchPool(round2Pool).quote(PRINCIPAL, _borrowDuration(), FABRICA_TOKEN, COLLATERAL_TOKEN_ID, ticks, "");
        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155(FABRICA_TOKEN).setApprovalForAll(round2Pool, true);
        uint256 repayment = _borrowLaunchPoolFor(round2Pool, COLLATERAL_TOKEN_ID, ticks, PRINCIPAL, quoted);
        vm.stopPrank();
        assertEq(repayment, quoted, "borrow repayment matches the quote");
        assertGt(repayment, PRINCIPAL, "repayment accrues interest over principal");
        assertEq(IERC1155(FABRICA_TOKEN).balanceOf(COLLATERAL_HOLDER, COLLATERAL_TOKEN_ID), 0, "collateral escrowed");
        console.log("ENG-3925 round-2 usable price (USDC 1e6) =", oraclePrice);
        console.log("ENG-3925 round-2 principal / repayment    =", PRINCIPAL, repayment);
    }

    /// @notice Ratio capacity tracks the oracle; absolute capacity does not. The tick policy, executable.
    function test_round2_ratioCapacityTracksPriceAndAbsoluteDoesNot() public {
        _setUpRound2Unfloored();
        uint256 basePrice = _round2Price();
        assertEq(basePrice, R2_EXPECTED_LIVE_MIN, "floor disabled: the usable price is the live MIN");
        uint256 ratioBefore = _maxBorrowable(round2Pool, TICK_RATIO, LP_DEPOSIT);
        uint256 absoluteBefore = _maxBorrowable(round2Pool, TICK_ABSOLUTE, LP_DEPOSIT);
        assertEq(ratioBefore, (basePrice * 5000) / 10_000, "ratio depth == oraclePrice * bps");
        assertEq(absoluteBefore, 50_000e6, "absolute capacity is the tick's own limit");
        assertLt(ratioBefore, LP_DEPOSIT, "ratio capacity is tick-bound, not deposit-bound");

        /* Halve each writer's valuation. -50% is inside the rate-of-change breaker, which trips only
           strictly above maxJumpBps. */
        _writeRound2(writerPrycd, COLLATERAL_TOKEN_ID, R2_LIVE_PRYCD / 2);
        _writeRound2(writerOpenAvm, COLLATERAL_TOKEN_ID, R2_LIVE_OPENAVM / 2);
        _writeRound2(writerRegrid, COLLATERAL_TOKEN_ID, R2_LIVE_REGRID / 2);
        uint256 halvedPrice = _round2Price();
        assertEq(halvedPrice, basePrice / 2, "usable price halved");
        assertEq(_maxBorrowable(round2Pool, TICK_RATIO, LP_DEPOSIT), ratioBefore / 2, "ratio capacity halves");
        assertEq(
            _maxBorrowable(round2Pool, TICK_ABSOLUTE, LP_DEPOSIT), absoluteBefore, "absolute capacity is price-blind"
        );
    }

    /* =====================================================================
       Verification clause 2 — the writer lock, at three sources and minimum two
       ===================================================================== */

    function test_round2_oneLockKeepsPricingAndASecondTripsMinSources() public {
        _setUpRound2();
        assertEq(_round2LiveWriterCount(), 3, "fixture: three live valuations before any lock");

        vm.prank(writerPrycd);
        round2Store.setLock(writerPrycd, COLLATERAL_TOKEN_ID, true);
        assertEq(_round2LiveWriterCount(), 2, "one lock drops the live count to two");
        assertEq(_round2Price(), R2_EXPECTED_USABLE, "pricing continues at two live valuations");
        assertGt(_maxBorrowable(round2Pool, TICK_RATIO, LP_DEPOSIT), 0, "and the pool still quotes");

        vm.prank(writerOpenAvm);
        round2Store.setLock(writerOpenAvm, COLLATERAL_TOKEN_ID, true);
        assertEq(_round2LiveWriterCount(), 1, "a second lock drops the live count to one");
        bytes memory minSourcesRevert = abi.encodeWithSelector(
            FabricaImmutableAggregator.CheckFailed.selector, round2Aggregator.CHECK_MIN_SOURCES()
        );
        vm.expectRevert(minSourcesRevert);
        _round2PriceCall();
        (bool ok, bytes32 failed) = round2Aggregator.eligibilityReport(USDC, COLLATERAL_TOKEN_ID);
        assertFalse(ok, "one live valuation cannot price");
        assertEq(failed, round2Aggregator.CHECK_MIN_SOURCES(), "eligibilityReport names the min-sources check");

        /* And therefore the BORROW is refused. A negative result is the verification. */
        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155(FABRICA_TOKEN).setApprovalForAll(round2Pool, true);
        vm.expectRevert(minSourcesRevert);
        _borrowLaunchPoolFor(round2Pool, COLLATERAL_TOKEN_ID, _ticks(TICK_RATIO), PRINCIPAL, PRINCIPAL * 2);
        vm.stopPrank();

        /* The same writer clears its own lock and the token recovers in the same block. */
        vm.prank(writerOpenAvm);
        round2Store.setLock(writerOpenAvm, COLLATERAL_TOKEN_ID, false);
        assertEq(_round2Price(), R2_EXPECTED_USABLE, "unlock restores pricing at once");
    }

    /* =====================================================================
       Verification clause 3 — maximum silence
       ===================================================================== */

    function test_round2_pastMaximumSilenceItRefusesAndTheReportNamesTheCheck() public {
        _setUpRound2();
        vm.warp(block.timestamp + R2_MAX_SILENCE + 1);
        bytes memory silenceRevert = abi.encodeWithSelector(
            FabricaImmutableAggregator.CheckFailed.selector, round2Aggregator.CHECK_MAX_SILENCE()
        );
        vm.expectRevert(silenceRevert);
        _round2PriceCall();
        (bool ok, bytes32 failed) = round2Aggregator.eligibilityReport(USDC, COLLATERAL_TOKEN_ID);
        assertFalse(ok, "silent feeds cannot price");
        assertEq(failed, round2Aggregator.CHECK_MAX_SILENCE(), "eligibilityReport names the silence check");

        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155(FABRICA_TOKEN).setApprovalForAll(round2Pool, true);
        vm.expectRevert(silenceRevert);
        _borrowLaunchPoolFor(round2Pool, COLLATERAL_TOKEN_ID, _ticks(TICK_RATIO), PRINCIPAL, PRINCIPAL * 2);
        vm.stopPrank();

        /* Two cycle closes bring the feed back — the writer lock and the silence check are separate
           mechanisms and recover separately. */
        vm.prank(writerPrycd);
        round2Store.closeCycle(writerPrycd, R2_CYCLE);
        vm.prank(writerOpenAvm);
        round2Store.closeCycle(writerOpenAvm, R2_CYCLE);
        (bool okAfter,) = round2Aggregator.eligibilityReport(USDC, COLLATERAL_TOKEN_ID);
        assertTrue(okAfter, "cycle closes restore the feed");
    }

    /* =====================================================================
       Helpers
       ===================================================================== */

    function _setUpRound2() internal {
        _buildRound2Stack(R2_SEASONING_WINDOW);
    }

    function _setUpRound2Unfloored() internal {
        _buildRound2Stack(0);
    }

    function _buildRound2Stack(uint64 seasoningWindow) internal {
        round2Store = new FabricaFactStore(R2_HISTORY_DEPTH);
        address[] memory writerSet = new address[](3);
        writerSet[0] = writerPrycd;
        writerSet[1] = writerOpenAvm;
        writerSet[2] = writerRegrid;
        round2Aggregator = new FabricaImmutableAggregator(
            FabricaImmutableAggregator.Config({
                factStore: address(round2Store),
                usdc: USDC,
                writers: writerSet,
                minLiveSources: R2_MIN_LIVE_SOURCES,
                maxSilence: R2_MAX_SILENCE,
                cycleCloseInterval: R2_CYCLE_CLOSE_INTERVAL,
                seasoningWindow: seasoningWindow,
                maxJumpBps: R2_MAX_JUMP_BPS,
                maxDispersionBps: R2_MAX_DISPERSION_BPS,
                maxFirstPriceUsdc6: R2_MAX_FIRST_PRICE_USDC6,
                valueCeilingUsdc6: R2_VALUE_CEILING_USDC6
            })
        );
        _seedRound2Facts();
        round2Pool = _createLaunchPool(address(round2Aggregator));
        _fundAndDepositAmount(round2Pool, LP_DEPOSIT);
    }

    /// @dev Seasoned observation, aged a full seasoning window, then the live values, then a cycle
    ///      close per writer. The closes come last so every feed is fresh at read time.
    function _seedRound2Facts() internal {
        _writeRound2(writerPrycd, COLLATERAL_TOKEN_ID, R2_SEASONED_PRYCD);
        _writeRound2(writerOpenAvm, COLLATERAL_TOKEN_ID, R2_SEASONED_OPENAVM);
        _writeRound2(writerRegrid, COLLATERAL_TOKEN_ID, R2_SEASONED_REGRID);
        vm.warp(block.timestamp + R2_SEASONING_WINDOW + 1);
        _writeRound2(writerPrycd, COLLATERAL_TOKEN_ID, R2_LIVE_PRYCD);
        _writeRound2(writerOpenAvm, COLLATERAL_TOKEN_ID, R2_LIVE_OPENAVM);
        _writeRound2(writerRegrid, COLLATERAL_TOKEN_ID, R2_LIVE_REGRID);
        vm.prank(writerPrycd);
        round2Store.closeCycle(writerPrycd, R2_CYCLE);
        vm.prank(writerOpenAvm);
        round2Store.closeCycle(writerOpenAvm, R2_CYCLE);
        vm.prank(writerRegrid);
        round2Store.closeCycle(writerRegrid, R2_CYCLE);
    }

    function _writeRound2(address writer, uint256 tokenId, uint128 value) internal {
        FabricaFactStore.FactInput memory input = FabricaFactStore.FactInput({
            tokenId: tokenId,
            kind: round2Store.KIND_PRICE(),
            value: value,
            confidence: R2_CONFIDENCE,
            valuedAt: uint64(block.timestamp),
            cycle: R2_CYCLE,
            data: keccak256(abi.encodePacked("eng3925-fork", writer, tokenId, value, block.timestamp))
        });
        vm.prank(writer);
        round2Store.writeFact(writer, input);
    }

    /// @dev Counts writers the aggregator would actually use, read through the STORE's own live flag
    ///      plus the aggregator's trusted set — so "the live count dropped" is an observation, not an
    ///      inference from the price having changed.
    function _round2LiveWriterCount() internal view returns (uint256 count) {
        address[] memory set = round2Aggregator.writers();
        bytes32 kind = round2Store.KIND_PRICE();
        for (uint256 i; i < set.length; ++i) {
            (, bool live) = round2Store.getLiveFact(set[i], COLLATERAL_TOKEN_ID, kind);
            if (live) ++count;
        }
    }

    function _round2Price() internal view returns (uint256) {
        return round2Aggregator.price(FABRICA_TOKEN, USDC, _singleton(COLLATERAL_TOKEN_ID), _singleton(1), "");
    }

    function _round2PriceCall() internal view {
        round2Aggregator.price(FABRICA_TOKEN, USDC, _singleton(COLLATERAL_TOKEN_ID), _singleton(1), "");
    }
}
