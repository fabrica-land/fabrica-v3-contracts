// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaFactStore} from "../src/FabricaFactStore.sol";

/// @notice ENG-3924 — the round-2 permissionless fact store.
/// @dev Extends the invariant set ENG-3523 established against the round-1 store, translated to a
///      store with no privileged roles. The ENG-3523 cases that survive are the write-time band,
///      the rate limit, cycle invalidation with lazy rewrite, and the liveness record; the cases
///      that do not survive did so by decision, and each has a test here asserting the surface is
///      GONE rather than silently omitted (`test_noPrivilegedSurface_*`).
contract FabricaFactStoreTest is Test {
    uint8 internal constant HISTORY_DEPTH = 48;
    uint64 internal constant CYCLE = 100;
    uint256 internal constant TOKEN = 4388;
    uint128 internal constant PRICE = 250_000e6;
    uint24 internal constant CONFIDENCE = 7700;

    FabricaFactStore internal store;
    bytes32 internal kindPrice;
    bytes32 internal kindAttribute = keccak256("fabrica.fact.acreage");

    address internal prycd = makeAddr("eng3924-writer-prycd");
    address internal openAvm = makeAddr("eng3924-writer-openavm");
    address internal stranger = makeAddr("eng3924-stranger");

    function setUp() public virtual {
        store = new FabricaFactStore(HISTORY_DEPTH);
        kindPrice = store.KIND_PRICE();
        // A real deploy starts at a real wall-clock; leave room to warp backwards in valuedAt tests.
        vm.warp(1_788_000_000);
    }

    // -------------------------------------------------------------------------
    // Row isolation — the property the whole design rests on
    // -------------------------------------------------------------------------

    function test_rowIsolation_twoWritersSameTokenNeitherTouchesTheOther() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        _write(openAvm, TOKEN, kindPrice, PRICE * 2, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE, "prycd row holds its own value");
        assertEq(store.getFact(openAvm, TOKEN, kindPrice).value, PRICE * 2, "openavm row holds its own value");
        // Each writer moves only its own row.
        _write(prycd, TOKEN, kindPrice, PRICE + 1, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE + 1, "prycd write moved prycd");
        assertEq(store.getFact(openAvm, TOKEN, kindPrice).value, PRICE * 2, "prycd write did not move openavm");
    }

    function test_rowIsolation_strangerCannotWriteAnotherWritersRow() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, prycd, stranger));
        vm.prank(stranger);
        store.writeFact(prycd, _input(TOKEN, kindPrice, 1, CYCLE));
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE, "prycd value untouched by stranger");
    }

    function test_rowIsolation_strangerCannotLockAnotherWritersToken() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, prycd, stranger));
        vm.prank(stranger);
        store.setLock(prycd, TOKEN, true);
        assertFalse(store.locked(prycd, TOKEN), "prycd token not locked by stranger");
        assertTrue(store.isFactLive(prycd, TOKEN, kindPrice), "prycd fact still live");
    }

    function test_rowIsolation_strangerCannotUnlockAnotherWritersToken() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        vm.prank(prycd);
        store.setLock(prycd, TOKEN, true);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, prycd, stranger));
        vm.prank(stranger);
        store.setLock(prycd, TOKEN, false);
        assertTrue(store.locked(prycd, TOKEN), "lock survives a stranger's unlock attempt");
    }

    function test_rowIsolation_strangerCannotInvalidateAnotherWritersCycles() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, prycd, stranger));
        vm.prank(stranger);
        store.setMinValidCycle(prycd, CYCLE + 1);
        assertEq(store.minValidCycle(prycd), 0, "prycd floor untouched");
        assertTrue(store.isFactLive(prycd, TOKEN, kindPrice), "prycd fact still live");
    }

    function test_rowIsolation_strangerCannotCloseOrDeclareForAnotherWriter() public {
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, prycd, stranger));
        vm.prank(stranger);
        store.closeCycle(prycd, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, prycd, stranger));
        vm.prank(stranger);
        store.declarePolicy(prycd, _policy(1500, 5000, 1 hours, true));
        assertEq(store.lastCycleClose(prycd).closedAt, 0, "no close recorded for prycd");
        assertFalse(store.policyOf(prycd).bandDeclared, "no policy recorded for prycd");
    }

    function test_rowIsolation_kindsAreIndependentWithinOneWriterAndToken() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        _write(prycd, TOKEN, kindAttribute, 42, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE, "price kind holds its own value");
        assertEq(store.getFact(prycd, TOKEN, kindAttribute).value, 42, "attribute kind holds its own value");
        assertEq(store.historyLength(prycd, TOKEN, kindPrice), 0, "history is per kind");
    }

    // -------------------------------------------------------------------------
    // The writer lock — replaces round 1's central recovery-writer role
    // -------------------------------------------------------------------------

    function test_lock_takesEffectOnReadImmediatelyAndUnlockRecovers() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        assertTrue(store.isFactLive(prycd, TOKEN, kindPrice), "live before the lock");
        vm.prank(prycd);
        store.setLock(prycd, TOKEN, true);
        // Same block, no warp: the lock is not pending.
        assertFalse(store.isFactLive(prycd, TOKEN, kindPrice), "locked fact reads dead in the same block");
        (FabricaFactStore.Fact memory locked, bool liveWhileLocked) = store.getLiveFact(prycd, TOKEN, kindPrice);
        assertEq(locked.value, PRICE, "the value is still readable; it is the liveness that changes");
        assertFalse(liveWhileLocked, "getLiveFact agrees with isFactLive");
        vm.prank(prycd);
        store.setLock(prycd, TOKEN, false);
        assertTrue(store.isFactLive(prycd, TOKEN, kindPrice), "unlock recovers in the same block");
    }

    function test_lock_coversEveryKindForThatWriterAndToken() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        _write(prycd, TOKEN, kindAttribute, 42, CYCLE);
        vm.prank(prycd);
        store.setLock(prycd, TOKEN, true);
        assertFalse(store.isFactLive(prycd, TOKEN, kindPrice), "price kind locked");
        assertFalse(store.isFactLive(prycd, TOKEN, kindAttribute), "attribute kind locked");
    }

    function test_lock_isScopedToOneTokenAndOneWriter() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        _write(prycd, TOKEN + 1, kindPrice, PRICE, CYCLE);
        _write(openAvm, TOKEN, kindPrice, PRICE, CYCLE);
        vm.prank(prycd);
        store.setLock(prycd, TOKEN, true);
        assertFalse(store.isFactLive(prycd, TOKEN, kindPrice), "locked token is dead");
        assertTrue(store.isFactLive(prycd, TOKEN + 1, kindPrice), "the writer's other tokens are unaffected");
        assertTrue(store.isFactLive(openAvm, TOKEN, kindPrice), "the other writer's row is unaffected");
    }

    function test_lock_doesNotBlockTheWritersOwnWrites() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        vm.prank(prycd);
        store.setLock(prycd, TOKEN, true);
        // There is no gate before a write; a locked row still accepts one, and it reads dead until
        // the writer unlocks. Locking is a statement about use, not a freeze on the row.
        _write(prycd, TOKEN, kindPrice, PRICE + 1, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE + 1, "write landed under the lock");
        assertFalse(store.isFactLive(prycd, TOKEN, kindPrice), "still dead until unlocked");
    }

    // -------------------------------------------------------------------------
    // Cycle invalidation — ENG-3523's kill switch, now the writer's own
    // -------------------------------------------------------------------------

    function test_invalidation_killsSameBlockAndLazyRewriteRestores() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        vm.prank(prycd);
        store.setMinValidCycle(prycd, CYCLE + 1);
        assertFalse(store.isFactLive(prycd, TOKEN, kindPrice), "raising the floor kills in the same block");
        assertFalse(store.isCycleValid(prycd, CYCLE), "the old cycle is invalid");
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE + 1);
        assertTrue(store.isFactLive(prycd, TOKEN, kindPrice), "a rewrite at the new floor restores the token");
    }

    function test_invalidation_isPerWriter() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        _write(openAvm, TOKEN, kindPrice, PRICE, CYCLE);
        vm.prank(prycd);
        store.setMinValidCycle(prycd, CYCLE + 1);
        assertFalse(store.isFactLive(prycd, TOKEN, kindPrice), "prycd killed its own facts");
        assertTrue(store.isFactLive(openAvm, TOKEN, kindPrice), "openavm is untouched");
        assertEq(store.minValidCycle(openAvm), 0, "openavm floor untouched");
    }

    function test_invalidation_floorOnlyRises() public {
        vm.startPrank(prycd);
        store.setMinValidCycle(prycd, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.CycleNotMonotonic.selector, CYCLE, CYCLE - 1));
        store.setMinValidCycle(prycd, CYCLE - 1);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.CycleNotMonotonic.selector, CYCLE, CYCLE));
        store.setMinValidCycle(prycd, CYCLE);
        vm.stopPrank();
        assertEq(store.minValidCycle(prycd), CYCLE, "floor unchanged by both rejected calls");
    }

    function test_invalidation_writeBelowTheFloorReverts() public {
        vm.prank(prycd);
        store.setMinValidCycle(prycd, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.CycleBelowFloor.selector, CYCLE, CYCLE - 1));
        vm.prank(prycd);
        store.writeFact(prycd, _input(TOKEN, kindPrice, PRICE, CYCLE - 1));
    }

    // -------------------------------------------------------------------------
    // The writer's own declared limits — round 1's owner knobs, re-homed
    // -------------------------------------------------------------------------

    function test_policy_undeclaredWriterIsBoundByNeitherBandNorInterval() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        // Same block, and a 10x move: neither the rate limit nor the band exists until declared.
        _write(prycd, TOKEN, kindPrice, PRICE * 10, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE * 10, "unconstrained write landed");
    }

    function test_policy_declaredBandRejectsOutOfBandAndAcceptsInBand() public {
        vm.prank(prycd);
        store.declarePolicy(prycd, _policy(1500, 5000, 0, true));
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        uint128 tooHigh = uint128((uint256(PRICE) * 11_501) / 10_000);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.BandExceeded.selector, PRICE, tooHigh, 1500, 5000));
        vm.prank(prycd);
        store.writeFact(prycd, _input(TOKEN, kindPrice, tooHigh, CYCLE));
        uint128 atCap = uint128((uint256(PRICE) * 11_500) / 10_000);
        _write(prycd, TOKEN, kindPrice, atCap, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, atCap, "the write exactly at the cap is accepted");
    }

    function test_policy_declaredBandRejectsBelowTheFloorOfTheBand() public {
        vm.prank(prycd);
        store.declarePolicy(prycd, _policy(1500, 5000, 0, true));
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        uint128 tooLow = uint128(uint256(PRICE) / 2 - 1);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.BandExceeded.selector, PRICE, tooLow, 1500, 5000));
        vm.prank(prycd);
        store.writeFact(prycd, _input(TOKEN, kindPrice, tooLow, CYCLE));
    }

    function test_policy_bandDoesNotApplyToTheFirstWriteOfARow() public {
        vm.prank(prycd);
        store.declarePolicy(prycd, _policy(1500, 5000, 0, true));
        // No previous value exists to measure a move against, so any first value is accepted.
        _write(prycd, TOKEN, kindPrice, type(uint128).max, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, type(uint128).max, "first write is unbanded");
    }

    /// @dev Regression for the zero-baseline band. A zero `value` is a legitimate present fact
    ///      (presence is `writtenAt`), and before the fix every percentage of that zero baseline
    ///      was also zero, so a declared band pinned the row at zero permanently: the widest
    ///      possible band still rejected a write of 1.
    function test_policy_zeroBaselineIsUnbandedNotPinnedToZero() public {
        vm.startPrank(prycd);
        store.declarePolicy(prycd, _policy(type(uint16).max, 10_000, 0, true));
        store.writeFact(prycd, _input(TOKEN, kindAttribute, 0, CYCLE));
        vm.stopPrank();
        assertTrue(store.isFactLive(prycd, TOKEN, kindAttribute), "the zero-valued fact is present");
        _write(prycd, TOKEN, kindAttribute, 1, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindAttribute).value, 1, "a write off a zero baseline is accepted");
        // And once a nonzero baseline exists the band applies again, so the escape is scoped to zero.
        uint128 tooHigh = uint128(uint256(1) + (uint256(1) * uint256(type(uint16).max)) / 10_000 + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaFactStore.BandExceeded.selector, uint128(1), tooHigh, type(uint16).max, uint16(10_000)
            )
        );
        vm.prank(prycd);
        store.writeFact(prycd, _input(TOKEN, kindAttribute, tooHigh, CYCLE));
    }

    function test_policy_minWriteIntervalRejectsThenAllowsAfterTheInterval() public {
        vm.prank(prycd);
        store.declarePolicy(prycd, _policy(0, 0, 1 hours, false));
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        uint64 writtenAt = store.getFact(prycd, TOKEN, kindPrice).writtenAt;
        vm.warp(block.timestamp + 1 hours - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaFactStore.WriteTooSoon.selector, writtenAt, uint64(1 hours), uint64(block.timestamp)
            )
        );
        vm.prank(prycd);
        store.writeFact(prycd, _input(TOKEN, kindPrice, PRICE, CYCLE));
        vm.warp(block.timestamp + 1);
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).writtenAt, uint64(block.timestamp), "write lands at interval");
    }

    function test_policy_isPerWriterNotGlobal() public {
        vm.prank(prycd);
        store.declarePolicy(prycd, _policy(1500, 5000, 1 hours, true));
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        // openAvm declared nothing, so prycd's declaration does not bind it.
        _write(openAvm, TOKEN, kindPrice, PRICE, CYCLE);
        _write(openAvm, TOKEN, kindPrice, PRICE * 10, CYCLE);
        assertEq(store.getFact(openAvm, TOKEN, kindPrice).value, PRICE * 10, "openavm is unconstrained");
    }

    function test_policy_wideningIsAllowedAndObservable() public {
        vm.startPrank(prycd);
        store.declarePolicy(prycd, _policy(1500, 5000, 0, true));
        vm.stopPrank();
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        uint128 doubled = PRICE * 2;
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.BandExceeded.selector, PRICE, doubled, 1500, 5000));
        vm.prank(prycd);
        store.writeFact(prycd, _input(TOKEN, kindPrice, doubled, CYCLE));
        // A writer may widen its own band; the change emits, so a consumer can see it happen.
        vm.expectEmit(true, false, false, true, address(store));
        emit FabricaFactStore.PolicyDeclared(prycd, 20_000, 5000, 0, true);
        vm.prank(prycd);
        store.declarePolicy(prycd, _policy(20_000, 5000, 0, true));
        _write(prycd, TOKEN, kindPrice, doubled, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, doubled, "the widened band admits the write");
    }

    function test_policy_maxDownBpsAboveOneHundredPercentIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.InvalidBand.selector, uint16(10_001)));
        vm.prank(prycd);
        store.declarePolicy(prycd, _policy(1500, 10_001, 0, true));
    }

    function test_policy_deadBaselineSkipsBandAndInterval() public {
        vm.prank(prycd);
        store.declarePolicy(prycd, _policy(1500, 5000, 1 hours, true));
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        vm.prank(prycd);
        store.setMinValidCycle(prycd, CYCLE + 1);
        // The writer has disowned the stored value, so it is not a baseline: the rewrite is a fresh
        // first write and is bound by neither the band nor the rate limit, in the same block.
        _write(prycd, TOKEN, kindPrice, PRICE * 10, CYCLE + 1);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE * 10, "dead baseline does not band the rewrite");
    }

    // -------------------------------------------------------------------------
    // Cycle close — decoupled from writes, cycle number only
    // -------------------------------------------------------------------------

    function test_cycleClose_recordsCycleAndTimestamp() public {
        vm.prank(prycd);
        store.closeCycle(prycd, CYCLE);
        FabricaFactStore.CycleClose memory close = store.lastCycleClose(prycd);
        assertEq(close.cycle, CYCLE, "cycle recorded");
        assertEq(close.closedAt, uint64(block.timestamp), "closed at the block time");
    }

    function test_cycleClose_isNotTouchedByAWrite() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        FabricaFactStore.CycleClose memory close = store.lastCycleClose(prycd);
        assertEq(close.closedAt, 0, "a fact write does not close a cycle");
        assertEq(close.cycle, 0, "a fact write does not advance the closed cycle");
    }

    function test_cycleClose_isPerWriter() public {
        vm.prank(prycd);
        store.closeCycle(prycd, CYCLE);
        assertEq(store.lastCycleClose(openAvm).closedAt, 0, "one writer's close is not another's");
    }

    function test_cycleClose_recloseRefreshesTimestampWithoutClaimingProgress() public {
        vm.prank(prycd);
        store.closeCycle(prycd, CYCLE);
        vm.warp(block.timestamp + 1 days);
        vm.prank(prycd);
        store.closeCycle(prycd, CYCLE);
        FabricaFactStore.CycleClose memory close = store.lastCycleClose(prycd);
        assertEq(close.cycle, CYCLE, "cycle unchanged");
        assertEq(close.closedAt, uint64(block.timestamp), "timestamp refreshed");
    }

    function test_cycleClose_cannotGoBackwards() public {
        vm.startPrank(prycd);
        store.closeCycle(prycd, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.CycleNotMonotonic.selector, CYCLE, CYCLE - 1));
        store.closeCycle(prycd, CYCLE - 1);
        vm.stopPrank();
    }

    function test_cycleClose_belowTheWritersOwnFloorReverts() public {
        vm.startPrank(prycd);
        store.setMinValidCycle(prycd, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.CycleBelowFloor.selector, CYCLE, CYCLE - 1));
        store.closeCycle(prycd, CYCLE - 1);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Fact write mechanics
    // -------------------------------------------------------------------------

    function test_write_cycleIsMonotonicPerRow() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.CycleNotMonotonic.selector, CYCLE, CYCLE - 1));
        vm.prank(prycd);
        store.writeFact(prycd, _input(TOKEN, kindPrice, PRICE, CYCLE - 1));
    }

    function test_write_valuedAtInTheFutureReverts() public {
        uint64 future = uint64(block.timestamp + 1);
        FabricaFactStore.FactInput memory input = _input(TOKEN, kindPrice, PRICE, CYCLE);
        input.valuedAt = future;
        vm.expectRevert(
            abi.encodeWithSelector(FabricaFactStore.InvalidValuedAt.selector, future, uint64(block.timestamp))
        );
        vm.prank(prycd);
        store.writeFact(prycd, input);
    }

    function test_write_zeroValuedAtDefaultsToBlockTime() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).valuedAt, uint64(block.timestamp), "valuedAt defaulted");
    }

    function test_write_writtenAtIsBlockTimeNotCallerSupplied() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).writtenAt, uint64(block.timestamp), "writtenAt is block time");
    }

    function test_write_zeroValueIsAPresentFactNotAnAbsentOne() public {
        FabricaFactStore.FactInput memory input = _input(TOKEN, kindAttribute, 0, CYCLE);
        vm.prank(prycd);
        store.writeFact(prycd, input);
        // Presence is `writtenAt`, so a genuinely zero-valued fact is live rather than invisible.
        assertTrue(store.isFactLive(prycd, TOKEN, kindAttribute), "a zero-valued fact is present");
        assertEq(store.getFact(prycd, TOKEN, kindAttribute).value, 0, "and its value is zero");
    }

    function test_write_neverWrittenRowIsNotLive() public {
        assertFalse(store.isFactLive(prycd, TOKEN, kindPrice), "an unwritten row is not live");
        (, bool live) = store.getLiveFact(prycd, TOKEN, kindPrice);
        assertFalse(live, "getLiveFact agrees");
    }

    function test_write_carriesConfidenceAndData() public {
        FabricaFactStore.FactInput memory input = _input(TOKEN, kindPrice, PRICE, CYCLE);
        input.confidence = CONFIDENCE;
        input.data = keccak256("provenance");
        vm.prank(prycd);
        store.writeFact(prycd, input);
        FabricaFactStore.Fact memory fact = store.getFact(prycd, TOKEN, kindPrice);
        assertEq(fact.confidence, CONFIDENCE, "confidence stored");
        assertEq(fact.data, keccak256("provenance"), "data stored");
    }

    // -------------------------------------------------------------------------
    // History ring — the seasoning walk's backing store
    // -------------------------------------------------------------------------

    function test_history_isEmptyUntilAWriteSupersedesAnother() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        assertEq(store.historyLength(prycd, TOKEN, kindPrice), 0, "the first write supersedes nothing");
        _write(prycd, TOKEN, kindPrice, PRICE + 1, CYCLE);
        assertEq(store.historyLength(prycd, TOKEN, kindPrice), 1, "the second write pushes one entry");
        assertEq(store.getHistory(prycd, TOKEN, kindPrice, 0).value, PRICE, "the entry is the superseded value");
    }

    function test_history_isNewestFirst() public {
        for (uint128 i; i < 4; ++i) {
            _write(prycd, TOKEN, kindPrice, PRICE + i, CYCLE);
        }
        assertEq(store.historyLength(prycd, TOKEN, kindPrice), 3, "three supersessions");
        assertEq(store.getHistory(prycd, TOKEN, kindPrice, 0).value, PRICE + 2, "index 0 is the most recent");
        assertEq(store.getHistory(prycd, TOKEN, kindPrice, 1).value, PRICE + 1, "index 1 is older");
        assertEq(store.getHistory(prycd, TOKEN, kindPrice, 2).value, PRICE, "index 2 is oldest");
    }

    function test_history_wrapsAtDepthAndDropsTheOldest() public {
        // depth + 2 writes leave depth supersessions; the two oldest values fall off the ring.
        for (uint128 i; i < uint128(HISTORY_DEPTH) + 2; ++i) {
            _write(prycd, TOKEN, kindPrice, PRICE + i, CYCLE);
        }
        assertEq(store.historyLength(prycd, TOKEN, kindPrice), HISTORY_DEPTH, "length caps at the ring depth");
        assertEq(store.getHistory(prycd, TOKEN, kindPrice, 0).value, PRICE + HISTORY_DEPTH, "newest is the last super");
        assertEq(
            store.getHistory(prycd, TOKEN, kindPrice, HISTORY_DEPTH - 1).value, PRICE + 1, "oldest retained is PRICE+1"
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaFactStore.HistoryIndexOutOfBounds.selector, uint256(HISTORY_DEPTH), uint256(HISTORY_DEPTH)
            )
        );
        store.getHistory(prycd, TOKEN, kindPrice, HISTORY_DEPTH);
    }

    function test_history_outOfBoundsReadReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(FabricaFactStore.HistoryIndexOutOfBounds.selector, uint256(0), uint256(0))
        );
        store.getHistory(prycd, TOKEN, kindPrice, 0);
    }

    function test_history_retainsDeadCycleEntriesForTheReaderToFilter() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        vm.prank(prycd);
        store.setMinValidCycle(prycd, CYCLE + 1);
        _write(prycd, TOKEN, kindPrice, PRICE * 2, CYCLE + 1);
        FabricaFactStore.HistoryEntry memory entry = store.getHistory(prycd, TOKEN, kindPrice, 0);
        assertEq(entry.cycle, CYCLE, "the dead entry is retained with its own cycle");
        assertFalse(store.isCycleValid(prycd, entry.cycle), "and the reader can see it is dead");
    }

    function test_history_isPerWriterAndPerKind() public {
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        _write(prycd, TOKEN, kindPrice, PRICE + 1, CYCLE);
        assertEq(store.historyLength(openAvm, TOKEN, kindPrice), 0, "another writer's history is empty");
        assertEq(store.historyLength(prycd, TOKEN, kindAttribute), 0, "another kind's history is empty");
    }

    // -------------------------------------------------------------------------
    // The absence of a privileged surface — the point of the redeploy
    // -------------------------------------------------------------------------

    /// @notice Round 1's whole admin surface must be ABSENT from the deployed bytecode.
    /// @dev ENG-3523 asserted the round-1 owner could tighten knobs instantly; round 2's assertion
    ///      is that there is no owner to ask, checked against the bytecode rather than the source.
    ///
    ///      The first version of this probe could not actually prove that. It sent each selector
    ///      with NO arguments over `staticcall` and asserted only `!ok`, so a selector that existed
    ///      but reverted — on authorisation, on argument decoding, or because `staticcall` forbids
    ///      its state write — was indistinguishable from a selector that was never there. It would
    ///      have passed against a store that had every one of these functions.
    ///
    ///      So each probe now carries VALID arguments, goes over `call` rather than `staticcall` so
    ///      a state-changing function is not rejected for the wrong reason, and the verdict reads
    ///      the revert payload: this contract declares no `fallback`, so an absent selector reverts
    ///      with EMPTY return data, while an implemented function that reverts carries a reason.
    ///      `historyDepth()` is the positive control — without it, "everything reverted" would also
    ///      be satisfied by probing the wrong address.
    function test_noPrivilegedSurface_ownerAndAdminSelectorsDoNotExist() public {
        string[8] memory names = [
            "owner()",
            "renounceOwnership()",
            "transferOwnership(address)",
            "setKnobs(uint16,uint16,uint128,uint64,uint64,uint64,uint128)",
            "setSourceEnabled(uint8,bool)",
            "setPricePublisher(uint256,address,bool)",
            "setRecoveryWriter(uint256,address,bool)",
            "register(uint256,uint256)"
        ];
        bytes[] memory probes = new bytes[](8);
        probes[0] = abi.encodeWithSignature("owner()");
        probes[1] = abi.encodeWithSignature("renounceOwnership()");
        probes[2] = abi.encodeWithSignature("transferOwnership(address)", prycd);
        probes[3] = abi.encodeWithSignature(
            "setKnobs(uint16,uint16,uint128,uint64,uint64,uint64,uint128)",
            uint16(1500),
            uint16(5000),
            uint128(50_000_000e6),
            uint64(1 days),
            uint64(1 hours),
            uint64(1 days),
            uint128(50_000_000e6)
        );
        probes[4] = abi.encodeWithSignature("setSourceEnabled(uint8,bool)", uint8(0), true);
        probes[5] = abi.encodeWithSignature("setPricePublisher(uint256,address,bool)", uint256(1), prycd, true);
        probes[6] = abi.encodeWithSignature("setRecoveryWriter(uint256,address,bool)", uint256(1), prycd, true);
        probes[7] = abi.encodeWithSignature("register(uint256,uint256)", uint256(1), TOKEN);
        // Positive control first, and deliberately NOT owner(): if the probe cannot see a function
        // that IS present, then "everything reverted" proves nothing and would also be satisfied by
        // probing an empty address.
        (bool controlOk, bytes memory controlRet) = address(store).call(abi.encodeWithSignature("historyDepth()"));
        assertTrue(controlOk, "positive control: historyDepth() must dispatch on this address");
        assertEq(abi.decode(controlRet, (uint8)), HISTORY_DEPTH, "positive control returns the deployed value");
        // Offenders are collected rather than asserted one at a time, so a failing run names the
        // whole privileged surface it found instead of stopping at the first selector.
        string memory found = "";
        uint256 offenders;
        for (uint256 i; i < probes.length; ++i) {
            (bool ok, bytes memory ret) = address(store).call(probes[i]);
            // Absent dispatch: this contract declares no fallback, so an unknown selector reverts
            // with EMPTY return data. Anything else means the selector is implemented — whether it
            // succeeded, reverted on authorisation, or reverted inside the ABI decoder.
            if (ok || ret.length != 0) {
                offenders++;
                found = string.concat(found, " | ", names[i], ok ? " (SUCCEEDED)" : " (reverted WITH data)");
            }
        }
        assertEq(offenders, 0, string.concat("privileged selectors present on the store:", found));
    }

    function test_noPrivilegedSurface_anyAddressMayWriteItsOwnRowWithNoAuthorization() public {
        // No allowlist, no registration, no source enable: a never-seen address writes immediately.
        address newcomer = makeAddr("eng3924-unknown-source");
        _write(newcomer, TOKEN, kindPrice, PRICE, CYCLE);
        assertTrue(store.isFactLive(newcomer, TOKEN, kindPrice), "an unknown address publishes under its own name");
    }

    function test_noPrivilegedSurface_historyDepthIsTheOnlyDeployParameter() public {
        FabricaFactStore fresh = new FabricaFactStore(12);
        assertEq(fresh.historyDepth(), 12, "depth comes from the constructor");
        vm.expectRevert(FabricaFactStore.HistoryDepthZero.selector);
        new FabricaFactStore(0);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _input(uint256 tokenId, bytes32 kind, uint128 value, uint64 cycle)
        internal
        pure
        returns (FabricaFactStore.FactInput memory)
    {
        return FabricaFactStore.FactInput({
            tokenId: tokenId,
            kind: kind,
            value: value,
            confidence: CONFIDENCE,
            valuedAt: 0,
            cycle: cycle,
            data: bytes32(0)
        });
    }

    function _policy(uint16 maxUpBps, uint16 maxDownBps, uint64 minWriteInterval, bool bandDeclared)
        internal
        pure
        returns (FabricaFactStore.WriterPolicy memory)
    {
        return FabricaFactStore.WriterPolicy({
            maxUpBps: maxUpBps, maxDownBps: maxDownBps, minWriteInterval: minWriteInterval, bandDeclared: bandDeclared
        });
    }

    function _write(address writer, uint256 tokenId, bytes32 kind, uint128 value, uint64 cycle) internal {
        vm.prank(writer);
        store.writeFact(writer, _input(tokenId, kind, value, cycle));
    }
}
