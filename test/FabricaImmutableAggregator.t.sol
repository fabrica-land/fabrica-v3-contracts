// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, stdJson} from "forge-std/Test.sol";

import {FabricaFactStore} from "../src/FabricaFactStore.sol";
import {FabricaImmutableAggregator} from "../src/FabricaImmutableAggregator.sol";

/// @notice Stand-in for USDC. The aggregator only requires the currency address to hold code and to
///         be the one it was deployed against; it never calls it.
contract CurrencyStub {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @notice A store whose `KIND_PRICE` disagrees with the aggregator's, to prove the constructor pin.
contract WrongKindStore {
    function KIND_PRICE() external pure returns (bytes32) {
        return keccak256("not.the.price.kind");
    }
}

/// @notice ENG-3925 — unit suite for the round-2 immutable aggregator.
/// @dev Runs against the REAL round-2 `FabricaFactStore`, not a mock. The store is ownerless and
///      cheap to deploy, and every rule under test here is a rule about how the aggregator reads
///      what that store actually stores; a mock would let the two drift apart silently.
contract FabricaImmutableAggregatorTest is Test {
    using stdJson for string;

    /* Tim's numbers, 2026-09-03 18:12Z, plus the round-1 values the ticket carries forward. */
    uint8 internal constant MIN_LIVE_SOURCES = 2;
    uint64 internal constant MAX_SILENCE = 3 days;
    uint64 internal constant CYCLE_CLOSE_INTERVAL = 1 days;
    uint64 internal constant SEASONING_WINDOW = 24 hours;
    uint16 internal constant MAX_JUMP_BPS = 5000;
    uint16 internal constant MAX_DISPERSION_BPS = 20_000;
    uint128 internal constant MAX_FIRST_PRICE_USDC6 = 50_000_000e6;
    uint128 internal constant VALUE_CEILING_USDC6 = 50_000_000e6;
    uint8 internal constant HISTORY_DEPTH = 48;

    uint256 internal constant TOKEN_ID = 3561233430243998108;
    uint64 internal constant CYCLE = 1;
    uint24 internal constant CONFIDENCE = 9000;

    /* Deliberately unequal, with the LOWEST live value on the LAST writer, so a MIN assertion
       cannot be satisfied by "first writer" or "lowest address" semantics. */
    uint128 internal constant SEASONED_PRYCD = 84_000e6;
    uint128 internal constant SEASONED_OPENAVM = 82_000e6;
    uint128 internal constant SEASONED_REGRID = 80_000e6;
    uint128 internal constant LIVE_PRYCD = 92_000e6;
    uint128 internal constant LIVE_OPENAVM = 90_000e6;
    uint128 internal constant LIVE_REGRID = 88_000e6;
    uint128 internal constant EXPECTED_LIVE_MIN = LIVE_REGRID;
    /* The temporal floor takes MIN(live MIN, the MIN as of now - seasoningWindow), so the seasoned
       value — below every live value — is the usable price. Both halves are load-bearing. */
    uint128 internal constant EXPECTED_USABLE = SEASONED_REGRID;

    FabricaFactStore internal store;
    FabricaImmutableAggregator internal aggregator;
    address internal usdc;
    bytes32 internal kindPrice;

    address internal prycd = makeAddr("eng3925-writer-prycd");
    address internal openAvm = makeAddr("eng3925-writer-openavm");
    address internal regrid = makeAddr("eng3925-writer-regrid");
    address internal stranger = makeAddr("eng3925-untrusted-writer");

    function setUp() public {
        /* Start well clear of the epoch so `block.timestamp - seasoningWindow` and the maximum-
           silence arithmetic are exercised on realistic values rather than clamped at zero. */
        vm.warp(1_780_000_000);
        usdc = address(new CurrencyStub());
        store = new FabricaFactStore(HISTORY_DEPTH);
        kindPrice = store.KIND_PRICE();
        aggregator = new FabricaImmutableAggregator(_config());
        _seedSeasonedThenLive();
    }

    /* =====================================================================
       The immutability claim, asserted against the compiled ABI rather than
       by probing selectors.
       ===================================================================== */

    /// @notice Every external function is `view` or `pure`: no setter, no renounce, nothing to call.
    /// @dev A selector probe is the weaker test and ENG-3924's reviewer showed why — a privileged
    ///      function that reverts with empty data reads as absent to a probe. This reads the compiled
    ///      ABI and asserts the property that actually matters: the contract has NO state-mutating
    ///      external surface at all, so there is nothing for a probe to miss. Reading `out/` is
    ///      sound because `forge test` builds before it runs.
    function test_abi_hasNoStateMutatingFunctionAtAll() public view {
        string memory artifact = _artifact();
        uint256 functions;
        for (uint256 i; _entryExists(artifact, i); ++i) {
            if (keccak256(bytes(_entryString(artifact, i, "type"))) != keccak256("function")) continue;
            ++functions;
            string memory name = _entryString(artifact, i, "name");
            bytes32 mutability = keccak256(bytes(_entryString(artifact, i, "stateMutability")));
            assertTrue(
                mutability == keccak256("view") || mutability == keccak256("pure"),
                string.concat("state-mutating function on an immutable aggregator: ", name)
            );
        }
        assertGt(functions, 0, "ABI scan must actually find functions");
    }

    /// @notice The names a reviewer greps for are absent, and so is `owner`.
    function test_abi_carriesNoOwnerSetterOrRenounceName() public view {
        string memory artifact = _artifact();
        for (uint256 i; _entryExists(artifact, i); ++i) {
            if (keccak256(bytes(_entryString(artifact, i, "type"))) != keccak256("function")) continue;
            string memory name = _entryString(artifact, i, "name");
            assertFalse(_startsWith(name, "set"), string.concat("setter present: ", name));
            assertFalse(_contains(name, "renounce"), string.concat("renounce present: ", name));
            assertFalse(_contains(name, "owner"), string.concat("ownership surface present: ", name));
            assertFalse(_contains(name, "Ownership"), string.concat("ownership surface present: ", name));
        }
    }

    /* =====================================================================
       Construction
       ===================================================================== */

    function test_constructor_readsBackEveryParameter() public view {
        assertEq(address(aggregator.factStore()), address(store), "factStore");
        assertEq(aggregator.usdc(), usdc, "usdc");
        assertEq(aggregator.writerCount(), 3, "writerCount");
        assertEq(aggregator.minLiveSources(), MIN_LIVE_SOURCES, "minLiveSources");
        assertEq(aggregator.maxSilence(), MAX_SILENCE, "maxSilence");
        assertEq(aggregator.cycleCloseInterval(), CYCLE_CLOSE_INTERVAL, "cycleCloseInterval");
        assertEq(aggregator.seasoningWindow(), SEASONING_WINDOW, "seasoningWindow");
        assertEq(aggregator.maxJumpBps(), MAX_JUMP_BPS, "maxJumpBps");
        assertEq(aggregator.maxDispersionBps(), MAX_DISPERSION_BPS, "maxDispersionBps");
        assertEq(aggregator.maxFirstPriceUsdc6(), MAX_FIRST_PRICE_USDC6, "maxFirstPriceUsdc6");
        assertEq(aggregator.valueCeilingUsdc6(), VALUE_CEILING_USDC6, "valueCeilingUsdc6");
        assertEq(aggregator.KIND_PRICE(), store.KIND_PRICE(), "KIND_PRICE pinned to the store");
        address[] memory set = aggregator.writers();
        assertEq(set.length, 3, "writers length");
        assertEq(set[0], prycd, "writers[0]");
        assertEq(set[1], openAvm, "writers[1]");
        assertEq(set[2], regrid, "writers[2]");
        assertEq(aggregator.writerAt(2), regrid, "writerAt");
        assertTrue(aggregator.isTrustedWriter(openAvm), "configured writer is trusted");
        assertFalse(aggregator.isTrustedWriter(stranger), "unconfigured writer is not trusted");
        assertFalse(aggregator.isTrustedWriter(address(0)), "zero address is never trusted");
    }

    function test_constructor_rejectsWriterIndexOutOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(FabricaImmutableAggregator.WriterIndexOutOfBounds.selector, 3, 3));
        aggregator.writerAt(3);
    }

    function test_constructor_rejectsZeroFactStoreAndZeroUsdc() public {
        FabricaImmutableAggregator.Config memory config = _config();
        config.factStore = address(0);
        vm.expectRevert(FabricaImmutableAggregator.ZeroAddress.selector);
        new FabricaImmutableAggregator(config);
        config = _config();
        config.usdc = address(0);
        vm.expectRevert(FabricaImmutableAggregator.ZeroAddress.selector);
        new FabricaImmutableAggregator(config);
    }

    function test_constructor_rejectsCodelessFactStoreAndCurrency() public {
        FabricaImmutableAggregator.Config memory config = _config();
        config.factStore = makeAddr("eoa-not-a-store");
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);
        config = _config();
        config.usdc = makeAddr("eoa-not-a-currency");
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);
    }

    /// @notice A store of the wrong shape — the round-1 store included — cannot be wired in silently.
    function test_constructor_pinsKindPriceAgainstTheStore() public {
        WrongKindStore wrong = new WrongKindStore();
        FabricaImmutableAggregator.Config memory config = _config();
        config.factStore = address(wrong);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaImmutableAggregator.UnexpectedFactStoreKind.selector, aggregator.KIND_PRICE(), wrong.KIND_PRICE()
            )
        );
        new FabricaImmutableAggregator(config);
    }

    function test_constructor_rejectsEmptyDuplicateZeroAndOversizedWriterSets() public {
        FabricaImmutableAggregator.Config memory config = _config();
        config.writers = new address[](0);
        vm.expectRevert(FabricaImmutableAggregator.InvalidWriterSet.selector);
        new FabricaImmutableAggregator(config);

        config = _config();
        config.writers[2] = prycd;
        vm.expectRevert(abi.encodeWithSelector(FabricaImmutableAggregator.DuplicateWriter.selector, prycd));
        new FabricaImmutableAggregator(config);

        config = _config();
        config.writers[1] = address(0);
        vm.expectRevert(FabricaImmutableAggregator.ZeroAddress.selector);
        new FabricaImmutableAggregator(config);

        config = _config();
        config.writers = new address[](9);
        for (uint256 i; i < 9; ++i) {
            config.writers[i] = address(uint160(i + 1));
        }
        vm.expectRevert(FabricaImmutableAggregator.InvalidWriterSet.selector);
        new FabricaImmutableAggregator(config);
    }

    /// @notice The round-1 floor survives: there is no owner here to lower it later either way.
    function test_constructor_rejectsMinLiveSourcesBelowTwoAndAboveTheWriterSet() public {
        FabricaImmutableAggregator.Config memory config = _config();
        config.minLiveSources = 1;
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);

        config = _config();
        config.minLiveSources = 4;
        vm.expectRevert(FabricaImmutableAggregator.InvalidWriterSet.selector);
        new FabricaImmutableAggregator(config);
    }

    function test_constructor_rejectsDisabledThresholds() public {
        FabricaImmutableAggregator.Config memory config = _config();
        config.maxSilence = 0;
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);

        config = _config();
        config.cycleCloseInterval = 0;
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);

        config = _config();
        config.maxJumpBps = 0;
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);

        config = _config();
        config.maxDispersionBps = 9_999;
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);
    }

    function test_constructor_rejectsUnreachableOrAbsentValueBounds() public {
        FabricaImmutableAggregator.Config memory config = _config();
        config.maxFirstPriceUsdc6 = 0;
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);

        config = _config();
        config.valueCeilingUsdc6 = 0;
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);

        config = _config();
        config.maxFirstPriceUsdc6 = VALUE_CEILING_USDC6 + 1;
        vm.expectRevert(FabricaImmutableAggregator.InvalidConfig.selector);
        new FabricaImmutableAggregator(config);
    }

    /* =====================================================================
       Pricing
       ===================================================================== */

    function test_price_isMinAcrossSourcesFlooredByTheSeasonedObservation() public view {
        assertEq(_price(), EXPECTED_USABLE, "temporal floor over MIN of live valuations");
        assertLt(EXPECTED_USABLE, EXPECTED_LIVE_MIN, "fixture: the floor must actually bind");
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertTrue(ok, "eligible");
        assertEq(failed, bytes32(0), "no failed check when eligible");
    }

    /// @notice With the floor disabled the usable price is exactly the live MIN, on the LAST writer.
    function test_price_withoutSeasoningIsExactlyTheLiveMinimum() public {
        FabricaImmutableAggregator.Config memory config = _config();
        config.seasoningWindow = 0;
        FabricaImmutableAggregator unfloored = new FabricaImmutableAggregator(config);
        assertEq(
            unfloored.price(address(this), usdc, _singleton(TOKEN_ID), _singleton(1), ""),
            EXPECTED_LIVE_MIN,
            "MIN across live valuations"
        );
    }

    function test_price_rejectsAnyCurrencyOtherThanTheConfiguredUsdc() public {
        _expectCheck(aggregator.CHECK_CURRENCY());
        aggregator.price(address(this), makeAddr("not-usdc"), _singleton(TOKEN_ID), _singleton(1), "");
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(makeAddr("not-usdc"), TOKEN_ID);
        assertFalse(ok, "not eligible in a foreign currency");
        assertEq(failed, aggregator.CHECK_CURRENCY(), "eligibilityReport names the currency check");
    }

    function test_price_weightsByQuantityAndRejectsMalformedBaskets() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = TOKEN_ID;
        ids[1] = TOKEN_ID;
        uint256[] memory quantities = new uint256[](2);
        quantities[0] = 1;
        quantities[1] = 3;
        assertEq(
            aggregator.price(address(this), usdc, ids, quantities, ""),
            EXPECTED_USABLE,
            "quantity-weighted average of one price is that price"
        );

        quantities[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(FabricaImmutableAggregator.ZeroQuantity.selector, 1));
        aggregator.price(address(this), usdc, ids, quantities, "");

        vm.expectRevert(FabricaImmutableAggregator.InvalidLength.selector);
        aggregator.price(address(this), usdc, ids, _singleton(1), "");

        vm.expectRevert(FabricaImmutableAggregator.InvalidLength.selector);
        aggregator.price(address(this), usdc, new uint256[](0), new uint256[](0), "");
    }

    /* =====================================================================
       Maximum silence — per writer, and the ENG-3924 floor caveat
       ===================================================================== */

    /// @notice Exactly at the boundary the feed is still live; one second past it is not.
    function test_silence_boundaryIsInclusiveThenTheFeedGoesDark() public {
        vm.warp(block.timestamp + MAX_SILENCE);
        /* Three days on, the live values are themselves older than the seasoning window, so the
           temporal floor finds them rather than the seasoned observation and the usable price rises
           to the live MIN. That is the floor working, not failing: an increase has aged through. */
        assertEq(_price(), EXPECTED_LIVE_MIN, "a close exactly maxSilence old is still live");

        vm.warp(block.timestamp + 1);
        _expectCheck(aggregator.CHECK_MAX_SILENCE());
        _priceCall();
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "silent feeds cannot price");
        assertEq(failed, aggregator.CHECK_MAX_SILENCE(), "eligibilityReport names the silence check");
    }

    /// @notice A writer that has never closed a cycle is silent, not merely quiet.
    /// @dev A fact write does not close a cycle (ENG-3924), so liveness must never be inferred from
    ///      `writtenAt`. Two writers close, one only writes: the silent one contributes nothing, and
    ///      with minLiveSources 2 the token still prices off the other two.
    function test_silence_isNeverInferredFromAFactWrite() public {
        FabricaFactStore fresh = new FabricaFactStore(HISTORY_DEPTH);
        FabricaImmutableAggregator.Config memory config = _config();
        config.factStore = address(fresh);
        config.seasoningWindow = 0;
        FabricaImmutableAggregator agg = new FabricaImmutableAggregator(config);

        _write(fresh, prycd, TOKEN_ID, LIVE_PRYCD, CYCLE);
        _write(fresh, openAvm, TOKEN_ID, LIVE_OPENAVM, CYCLE);
        _write(fresh, regrid, TOKEN_ID, LIVE_REGRID, CYCLE);
        /* Every writer has a fact and none has closed a cycle. */
        (bool ok, bytes32 failed) = agg.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "facts alone are not liveness");
        assertEq(failed, agg.CHECK_MAX_SILENCE(), "silence, not min_sources");

        vm.prank(prycd);
        fresh.closeCycle(prycd, CYCLE);
        vm.prank(openAvm);
        fresh.closeCycle(openAvm, CYCLE);
        assertEq(
            agg.price(address(this), usdc, _singleton(TOKEN_ID), _singleton(1), ""),
            LIVE_OPENAVM,
            "two closed feeds price; the never-closed writer contributes nothing"
        );
    }

    /// @notice A recorded close can name a cycle the writer has since killed. Both must be checked.
    /// @dev The ENG-3924 handoff caveat, made executable: `closeCycle` refuses a cycle below the
    ///      floor at call time, but raising the floor afterwards does not rewrite the record, so
    ///      `lastCycleClose(w).cycle` can be a cycle `isCycleValid(w, cycle)` now reports false for.
    function test_silence_recordedCloseBelowTheWritersRaisedFloorIsNotLiveness() public {
        vm.prank(prycd);
        store.setMinValidCycle(prycd, CYCLE + 1);
        vm.prank(openAvm);
        store.setMinValidCycle(openAvm, CYCLE + 1);

        FabricaFactStore.CycleClose memory close = store.lastCycleClose(prycd);
        assertEq(close.cycle, CYCLE, "the close record still names the old cycle");
        assertGt(close.closedAt, 0, "and is recent enough to look live on timestamp alone");
        assertFalse(store.isCycleValid(prycd, close.cycle), "but the writer has disowned that cycle");

        _expectCheck(aggregator.CHECK_MAX_SILENCE());
        _priceCall();
    }

    /* =====================================================================
       The writer lock — the round-2 verification clause
       ===================================================================== */

    /// @notice Three live, minimum two: one lock leaves pricing up, a second lock takes it down.
    function test_lock_oneDropsToTwoAndPricesSecondTripsMinSources() public {
        vm.prank(prycd);
        store.setLock(prycd, TOKEN_ID, true);
        assertEq(_price(), EXPECTED_USABLE, "two live valuations still price");

        vm.prank(openAvm);
        store.setLock(openAvm, TOKEN_ID, true);
        _expectCheck(aggregator.CHECK_MIN_SOURCES());
        _priceCall();
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "one live valuation cannot price");
        assertEq(failed, aggregator.CHECK_MIN_SOURCES(), "eligibilityReport names the min-sources check");
        /* The feeds themselves are not silent — a lock is a statement about a token, and the check
           set has to keep the two apart or the refusal reason is misleading. */
        assertTrue(failed != aggregator.CHECK_MAX_SILENCE(), "a locked token is not a dark feed");
    }

    /// @notice Unlocking restores the token in the same block, with no pending state anywhere.
    function test_lock_isReversibleAndTakesEffectImmediately() public {
        vm.prank(prycd);
        store.setLock(prycd, TOKEN_ID, true);
        vm.prank(openAvm);
        store.setLock(openAvm, TOKEN_ID, true);
        _expectCheck(aggregator.CHECK_MIN_SOURCES());
        _priceCall();

        vm.prank(openAvm);
        store.setLock(openAvm, TOKEN_ID, false);
        assertEq(_price(), EXPECTED_USABLE, "unlock restores pricing at once");
    }

    /// @notice A writer's floor kills its own valuations immediately; two floors take the token down.
    function test_minValidCycle_invalidatesTheWritersOwnFactsAtOnce() public {
        vm.prank(prycd);
        store.setMinValidCycle(prycd, CYCLE + 1);
        assertEq(_price(), EXPECTED_USABLE, "one writer's floor leaves two live");

        vm.prank(openAvm);
        store.setMinValidCycle(openAvm, CYCLE + 1);
        /* Both writers are now silent as well as factless: their recorded close names a dead cycle,
           which is the caveat above, so the honest reason is silence. */
        _expectCheck(aggregator.CHECK_MAX_SILENCE());
        _priceCall();
    }

    /* =====================================================================
       Guards 4, 8 and 9, re-established from the round-1 store
       ===================================================================== */

    /// @notice Guard 4: a zero valuation is treated as absent, not as a price of zero.
    function test_guard4_zeroValuationIsAbsentNotAPriceOfZero() public {
        _write(store, regrid, TOKEN_ID, 0, CYCLE);
        (FabricaFactStore.Fact memory fact, bool live) = store.getLiveFact(regrid, TOKEN_ID, kindPrice);
        assertEq(fact.value, 0, "the store holds a present zero");
        assertTrue(live, "and calls it live - presence is writtenAt, and the store does not read kind");
        assertEq(_price(), SEASONED_OPENAVM, "the aggregator drops it; the floor falls to the next writer");

        _write(store, openAvm, TOKEN_ID, 0, CYCLE);
        _expectCheck(aggregator.CHECK_MIN_SOURCES());
        _priceCall();
    }

    /// @notice Guard 9: a valuation above the global ceiling is dropped at read time.
    function test_guard9_valuationAboveTheCeilingIsDropped() public {
        FabricaImmutableAggregator agg = _aggregatorWithBounds(1_000e6, 100_000e6);
        assertEq(agg.price(address(this), usdc, _singleton(TOKEN_ID), _singleton(1), ""), EXPECTED_USABLE, "baseline");

        /* Above the ceiling, and inside the rate-of-change breaker so the breaker is not what
           rejects it: 92,000 -> 100,001 is +8.7%, far under maxJumpBps. */
        _write(store, prycd, TOKEN_ID, 100_001e6, CYCLE);
        (, bool live) = store.getLiveFact(prycd, TOKEN_ID, kindPrice);
        assertTrue(live, "the store still calls it live - the ceiling is the aggregator's");
        (bool ok,) = agg.eligibilityReport(usdc, TOKEN_ID);
        assertTrue(ok, "two writers remain");

        _write(store, openAvm, TOKEN_ID, 100_001e6, CYCLE);
        (bool okAfter, bytes32 failed) = agg.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(okAfter, "two dropped valuations take the token below the minimum");
        assertEq(failed, agg.CHECK_MIN_SOURCES(), "reported as min_sources");
    }

    /// @notice Guard 8: a writer's FIRST valuation for a row is capped separately from the ceiling.
    /// @dev Isolated with a first-price cap strictly below the ceiling. At the round-1 deploy values
    ///      the two are equal (both 50,000,000 USDC), so guard 9 would fire first and guard 8 would
    ///      be unobservable — see the note in the PR body.
    function test_guard8_firstValuationAboveTheCapIsDroppedButAtTheCapIsKept() public {
        uint128 cap = 1_000e6;
        FabricaImmutableAggregator agg = _aggregatorWithBounds(cap, VALUE_CEILING_USDC6);
        uint256 freshToken = TOKEN_ID + 8;

        _write(store, prycd, freshToken, cap + 1, CYCLE);
        _write(store, openAvm, freshToken, cap + 1, CYCLE);
        _write(store, regrid, freshToken, cap + 1, CYCLE);
        (bool ok, bytes32 failed) = agg.eligibilityReport(usdc, freshToken);
        assertFalse(ok, "every first valuation is over the cap");
        assertEq(failed, agg.CHECK_MIN_SOURCES(), "over-cap first valuations are absent, not silent");

        /* Exactly at the cap is permitted — the round-1 store reverted only strictly above it. */
        uint256 atCapToken = TOKEN_ID + 9;
        _write(store, prycd, atCapToken, cap, CYCLE);
        _write(store, openAvm, atCapToken, cap, CYCLE);
        assertEq(
            agg.price(address(this), usdc, _singleton(atCapToken), _singleton(1), ""),
            cap,
            "a first valuation exactly at the cap is kept"
        );
    }

    /// @notice Guard 8 binds only the first valuation: once a row has history the ceiling is the bound.
    function test_guard8_doesNotBindAfterTheRowHasHistory() public {
        uint128 cap = 100_000e6;
        FabricaImmutableAggregator agg = _aggregatorWithBounds(cap, VALUE_CEILING_USDC6);
        uint256 token = TOKEN_ID + 10;
        _write(store, prycd, token, 90_000e6, CYCLE);
        _write(store, openAvm, token, 90_000e6, CYCLE);
        assertEq(store.historyLength(prycd, token, kindPrice), 0, "no supersession yet");

        /* A second write pushes history, so the first-price cap no longer applies. +11% keeps the
           rate-of-change breaker out of the picture. */
        _write(store, prycd, token, 100_001e6, CYCLE);
        _write(store, openAvm, token, 100_001e6, CYCLE);
        assertEq(store.historyLength(prycd, token, kindPrice), 1, "supersession recorded");
        assertEq(
            agg.price(address(this), usdc, _singleton(token), _singleton(1), ""),
            100_001e6,
            "above the first-price cap but with history: kept"
        );
    }

    /* =====================================================================
       Breakers
       ===================================================================== */

    /// @notice Rate of change: a jump past maxJumpBps drops that feed, not the whole token.
    function test_breaker_rateOfChangeDropsTheJumpingFeed() public {
        /* 88,000 -> 140,000 is +59%, past the 50% breaker. */
        _write(store, regrid, TOKEN_ID, 140_000e6, CYCLE);
        assertEq(_price(), SEASONED_OPENAVM, "the jumping feed is dropped; the floor moves up one writer");

        _write(store, openAvm, TOKEN_ID, 140_000e6, CYCLE);
        _expectCheck(aggregator.CHECK_MIN_SOURCES());
        _priceCall();
    }

    /// @notice A raised floor disowns the baseline, so the first valid rewrite is not a "jump".
    function test_breaker_baselineBelowTheWritersFloorDoesNotTrip() public {
        vm.prank(regrid);
        store.setMinValidCycle(regrid, CYCLE + 1);
        vm.prank(regrid);
        store.closeCycle(regrid, CYCLE + 1);
        /* The prior value is stamped with a cycle the writer has disowned, so this large move is a
           fresh baseline rather than a breach. */
        _write(store, regrid, TOKEN_ID, 140_000e6, CYCLE + 1);
        (bool ok,) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertTrue(ok, "a rewrite over a dead baseline is not a breaker trip");
    }

    /// @notice Dispersion: valuations that disagree by more than the configured ratio refuse.
    function test_dispersion_refusesWhenSourcesDisagreeTooWidely() public {
        FabricaImmutableAggregator agg = _aggregatorWithDispersion(11_000);
        (bool ok,) = agg.eligibilityReport(usdc, TOKEN_ID);
        assertTrue(ok, "92,000 / 88,000 = 10,454 bps is inside an 11,000 bps limit");

        FabricaImmutableAggregator tight = _aggregatorWithDispersion(10_400);
        (bool okTight, bytes32 failed) = tight.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(okTight, "the same spread is outside a 10,400 bps limit");
        assertEq(failed, tight.CHECK_DISPERSION(), "eligibilityReport names the dispersion check");
    }

    /* =====================================================================
       Round-2 rules about which valuation counts
       ===================================================================== */

    /// @notice Only the newest write per writer and token is considered.
    function test_newestWritePerWriterAndTokenIsTheOnlyValuationConsidered() public {
        FabricaImmutableAggregator.Config memory config = _config();
        config.seasoningWindow = 0;
        FabricaImmutableAggregator unfloored = new FabricaImmutableAggregator(config);
        assertEq(
            unfloored.price(address(this), usdc, _singleton(TOKEN_ID), _singleton(1), ""),
            EXPECTED_LIVE_MIN,
            "baseline is the current MIN"
        );
        /* Raise the lowest writer above the others. The old, lower value is now history, and with
           the floor disabled nothing may read it. */
        _write(store, regrid, TOKEN_ID, 95_000e6, CYCLE);
        assertEq(
            unfloored.price(address(this), usdc, _singleton(TOKEN_ID), _singleton(1), ""),
            LIVE_OPENAVM,
            "the superseded value is not considered"
        );
    }

    /// @notice A writer outside the trusted set is invisible however loudly it writes.
    function test_untrustedWriterIsIgnoredEntirely() public {
        uint256 token = TOKEN_ID + 11;
        vm.prank(stranger);
        store.closeCycle(stranger, CYCLE);
        _write(store, stranger, token, 1e6, CYCLE);
        _write(store, prycd, token, 90_000e6, CYCLE);

        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, token);
        assertFalse(ok, "one trusted valuation plus a stranger is still one valuation");
        assertEq(failed, aggregator.CHECK_MIN_SOURCES(), "min_sources");

        _write(store, openAvm, token, 90_000e6, CYCLE);
        assertEq(
            aggregator.price(address(this), usdc, _singleton(token), _singleton(1), ""),
            90_000e6,
            "the stranger's 1 USDC never became the MIN"
        );
    }

    /* =====================================================================
       Helpers
       ===================================================================== */

    function _config() internal view returns (FabricaImmutableAggregator.Config memory) {
        address[] memory writerSet = new address[](3);
        writerSet[0] = prycd;
        writerSet[1] = openAvm;
        writerSet[2] = regrid;
        return FabricaImmutableAggregator.Config({
            factStore: address(store),
            usdc: usdc,
            writers: writerSet,
            minLiveSources: MIN_LIVE_SOURCES,
            maxSilence: MAX_SILENCE,
            cycleCloseInterval: CYCLE_CLOSE_INTERVAL,
            seasoningWindow: SEASONING_WINDOW,
            maxJumpBps: MAX_JUMP_BPS,
            maxDispersionBps: MAX_DISPERSION_BPS,
            maxFirstPriceUsdc6: MAX_FIRST_PRICE_USDC6,
            valueCeilingUsdc6: VALUE_CEILING_USDC6
        });
    }

    function _aggregatorWithBounds(uint128 firstPriceCap, uint128 ceiling)
        internal
        returns (FabricaImmutableAggregator)
    {
        FabricaImmutableAggregator.Config memory config = _config();
        config.maxFirstPriceUsdc6 = firstPriceCap;
        config.valueCeilingUsdc6 = ceiling;
        return new FabricaImmutableAggregator(config);
    }

    function _aggregatorWithDispersion(uint16 maxDispersionBps) internal returns (FabricaImmutableAggregator) {
        FabricaImmutableAggregator.Config memory config = _config();
        config.maxDispersionBps = maxDispersionBps;
        /* The dispersion breaker reads the LIVE spread, so the floor is disabled here to keep the
           assertion about dispersion rather than about seasoning. */
        config.seasoningWindow = 0;
        return new FabricaImmutableAggregator(config);
    }

    /// @dev Seeds a seasoned observation, ages it a full seasoning window, then writes the live
    ///      values and closes every writer's cycle, so the temporal floor has something older than
    ///      `now - seasoningWindow` to find and every feed reads as live.
    function _seedSeasonedThenLive() internal {
        _write(store, prycd, TOKEN_ID, SEASONED_PRYCD, CYCLE);
        _write(store, openAvm, TOKEN_ID, SEASONED_OPENAVM, CYCLE);
        _write(store, regrid, TOKEN_ID, SEASONED_REGRID, CYCLE);
        vm.warp(block.timestamp + SEASONING_WINDOW + 1);
        _write(store, prycd, TOKEN_ID, LIVE_PRYCD, CYCLE);
        _write(store, openAvm, TOKEN_ID, LIVE_OPENAVM, CYCLE);
        _write(store, regrid, TOKEN_ID, LIVE_REGRID, CYCLE);
        vm.prank(prycd);
        store.closeCycle(prycd, CYCLE);
        vm.prank(openAvm);
        store.closeCycle(openAvm, CYCLE);
        vm.prank(regrid);
        store.closeCycle(regrid, CYCLE);
    }

    function _write(FabricaFactStore target, address writer, uint256 tokenId, uint128 value, uint64 cycle) internal {
        FabricaFactStore.FactInput memory input = FabricaFactStore.FactInput({
            tokenId: tokenId,
            kind: target.KIND_PRICE(),
            value: value,
            confidence: CONFIDENCE,
            valuedAt: uint64(block.timestamp),
            cycle: cycle,
            data: keccak256(abi.encodePacked("eng3925", writer, tokenId, value, cycle))
        });
        vm.prank(writer);
        target.writeFact(writer, input);
    }

    function _price() internal view returns (uint256) {
        return aggregator.price(address(this), usdc, _singleton(TOKEN_ID), _singleton(1), "");
    }

    function _priceCall() internal view {
        aggregator.price(address(this), usdc, _singleton(TOKEN_ID), _singleton(1), "");
    }

    function _expectCheck(bytes32 checkId) internal {
        vm.expectRevert(abi.encodeWithSelector(FabricaImmutableAggregator.CheckFailed.selector, checkId));
    }

    function _singleton(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    function _artifact() internal view returns (string memory) {
        return vm.readFile("out/FabricaImmutableAggregator.sol/FabricaImmutableAggregator.json");
    }

    /// @dev Walks the ABI array by index. A JSONPath filter returning many values is rejected by
    ///      `parseJsonStringArray`, so the entries are read one at a time until the index runs out.
    function _entryExists(string memory artifact, uint256 index) internal view returns (bool) {
        return vm.keyExistsJson(artifact, string.concat(".abi[", vm.toString(index), "]"));
    }

    function _entryString(string memory artifact, uint256 index, string memory field)
        internal
        view
        returns (string memory)
    {
        string memory path = string.concat(".abi[", vm.toString(index), "].", field);
        if (!vm.keyExistsJson(artifact, path)) return "";
        return artifact.readString(path);
    }

    function _startsWith(string memory value, string memory prefix) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory prefixBytes = bytes(prefix);
        if (prefixBytes.length > valueBytes.length) return false;
        for (uint256 i; i < prefixBytes.length; ++i) {
            if (valueBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function _contains(string memory value, string memory needle) internal pure returns (bool) {
        bytes memory valueBytes = bytes(value);
        bytes memory needleBytes = bytes(needle);
        if (needleBytes.length == 0 || needleBytes.length > valueBytes.length) return false;
        for (uint256 i; i <= valueBytes.length - needleBytes.length; ++i) {
            bool matched = true;
            for (uint256 j; j < needleBytes.length; ++j) {
                if (valueBytes[i + j] != needleBytes[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }
}
