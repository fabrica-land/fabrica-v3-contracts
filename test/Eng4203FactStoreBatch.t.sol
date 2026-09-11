// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {FabricaFactStore} from "../src/FabricaFactStore.sol";

/// @notice ENG-4203 — `writeFacts` batch entry point.
/// @dev Inner custom errors bubble unchanged (no BatchInputFailed wrapper). Empty and oversized
///      batches have named entry errors. A batch write does not close a cycle.
contract Eng4203FactStoreBatchTest is Test {
    uint8 internal constant HISTORY_DEPTH = 48;
    uint64 internal constant CYCLE = 100;
    uint256 internal constant TOKEN = 4388;
    uint128 internal constant PRICE = 250_000e6;
    uint24 internal constant CONFIDENCE = 7700;

    FabricaFactStore internal store;
    bytes32 internal kindPrice;
    bytes32 internal kindAttribute = keccak256("fabrica.fact.acreage");

    address internal prycd = makeAddr("eng4203-writer-prycd");
    address internal stranger = makeAddr("eng4203-stranger");

    function setUp() public {
        store = new FabricaFactStore(HISTORY_DEPTH);
        kindPrice = store.KIND_PRICE();
        vm.warp(1_788_000_000);
    }

    function test_writeFacts_parityWithNWriteFactCalls_factsHistoryEvents() public {
        uint256 n = 4;
        FabricaFactStore.FactInput[] memory inputs = _mixedInputs(n);
        FabricaFactStore singles = new FabricaFactStore(HISTORY_DEPTH);
        vm.recordLogs();
        for (uint256 i; i < n; ++i) {
            vm.prank(prycd);
            singles.writeFact(prycd, inputs[i]);
        }
        Vm.Log[] memory singleLogs = vm.getRecordedLogs();
        vm.recordLogs();
        vm.prank(prycd);
        store.writeFacts(prycd, inputs);
        Vm.Log[] memory batchLogs = vm.getRecordedLogs();
        _assertFactParity(singles, store, inputs);
        _assertLogParity(singleLogs, batchLogs);
    }

    function test_writeFacts_mixesTokenIdsAndKindsSameWriter() public {
        FabricaFactStore.FactInput[] memory inputs = new FabricaFactStore.FactInput[](2);
        inputs[0] = _input(TOKEN, kindPrice, PRICE, CYCLE);
        inputs[1] = _input(TOKEN, kindAttribute, 12, CYCLE);
        vm.prank(prycd);
        store.writeFacts(prycd, inputs);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE, "price row");
        assertEq(store.getFact(prycd, TOKEN, kindAttribute).value, 12, "attribute row");
        assertTrue(store.isFactLive(prycd, TOKEN, kindPrice), "price live");
        assertTrue(store.isFactLive(prycd, TOKEN, kindAttribute), "attribute live");
    }

    function test_writeFacts_policyRevertRollsBackEarlierInputsAndBubblesInnerError() public {
        vm.prank(prycd);
        store.declarePolicy(prycd, _policy(1500, 5000, 0, true));
        _write(prycd, TOKEN, kindPrice, PRICE, CYCLE);
        uint128 tooHigh = PRICE * 2;
        FabricaFactStore.FactInput[] memory inputs = new FabricaFactStore.FactInput[](3);
        inputs[0] = _input(TOKEN + 1, kindPrice, PRICE, CYCLE);
        inputs[1] = _input(TOKEN, kindPrice, tooHigh, CYCLE);
        inputs[2] = _input(TOKEN + 2, kindPrice, PRICE, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.BandExceeded.selector, PRICE, tooHigh, 1500, 5000));
        vm.prank(prycd);
        store.writeFacts(prycd, inputs);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE, "baseline survives");
        assertEq(store.getFact(prycd, TOKEN + 1, kindPrice).writtenAt, 0, "earlier batch input rolled back");
        assertEq(store.getFact(prycd, TOKEN + 2, kindPrice).writtenAt, 0, "later batch input never landed");
    }

    function test_writeFacts_emptyBatchReverts() public {
        FabricaFactStore.FactInput[] memory inputs = new FabricaFactStore.FactInput[](0);
        vm.expectRevert(FabricaFactStore.EmptyBatch.selector);
        vm.prank(prycd);
        store.writeFacts(prycd, inputs);
    }

    function test_writeFacts_maxBatchPlusOneReverts() public {
        uint256 n = store.MAX_BATCH() + 1;
        FabricaFactStore.FactInput[] memory inputs = new FabricaFactStore.FactInput[](n);
        for (uint256 i; i < n; ++i) {
            inputs[i] = _input(TOKEN + i, kindPrice, PRICE, CYCLE);
        }
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.BatchTooLarge.selector, n, store.MAX_BATCH()));
        vm.prank(prycd);
        store.writeFacts(prycd, inputs);
    }

    function test_writeFacts_maxBatchSucceeds() public {
        uint256 n = store.MAX_BATCH();
        FabricaFactStore.FactInput[] memory inputs = new FabricaFactStore.FactInput[](n);
        for (uint256 i; i < n; ++i) {
            inputs[i] = _input(TOKEN + i, kindPrice, PRICE, CYCLE);
        }
        vm.prank(prycd);
        store.writeFacts(prycd, inputs);
        (FabricaFactStore.Fact memory last, bool live) = store.getLiveFact(prycd, TOKEN + n - 1, kindPrice);
        assertTrue(live, "last row live");
        assertEq(last.value, PRICE, "last row value");
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE, "first row value");
    }

    function test_writeFacts_notWriterRevertsBeforeLoop() public {
        FabricaFactStore.FactInput[] memory inputs = new FabricaFactStore.FactInput[](1);
        inputs[0] = _input(TOKEN, kindPrice, PRICE, CYCLE);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, prycd, stranger));
        vm.prank(stranger);
        store.writeFacts(prycd, inputs);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).writtenAt, 0, "stranger wrote nothing");
    }

    function test_writeFacts_doesNotCloseACycle() public {
        FabricaFactStore.FactInput[] memory inputs = new FabricaFactStore.FactInput[](1);
        inputs[0] = _input(TOKEN, kindPrice, PRICE, CYCLE);
        vm.prank(prycd);
        store.writeFacts(prycd, inputs);
        FabricaFactStore.CycleClose memory close = store.lastCycleClose(prycd);
        assertEq(close.cycle, 0, "cycle number untouched");
        assertEq(close.closedAt, 0, "closedAt untouched");
    }

    function test_writeFacts_sameRowTwiceInOneBatchPushesHistory() public {
        FabricaFactStore.FactInput[] memory inputs = new FabricaFactStore.FactInput[](2);
        inputs[0] = _input(TOKEN, kindPrice, PRICE, CYCLE);
        inputs[1] = _input(TOKEN, kindPrice, PRICE + 1, CYCLE);
        vm.prank(prycd);
        store.writeFacts(prycd, inputs);
        assertEq(store.getFact(prycd, TOKEN, kindPrice).value, PRICE + 1, "current is the second write");
        assertEq(store.historyLength(prycd, TOKEN, kindPrice), 1, "first write is history");
        assertEq(store.getHistory(prycd, TOKEN, kindPrice, 0).value, PRICE, "history[0] is the superseded value");
    }

    function _assertFactParity(
        FabricaFactStore singles,
        FabricaFactStore batched,
        FabricaFactStore.FactInput[] memory inputs
    ) internal view {
        for (uint256 i; i < inputs.length; ++i) {
            uint256 tokenId = inputs[i].tokenId;
            bytes32 kind = inputs[i].kind;
            FabricaFactStore.Fact memory a = singles.getFact(prycd, tokenId, kind);
            FabricaFactStore.Fact memory b = batched.getFact(prycd, tokenId, kind);
            assertEq(a.value, b.value, "value");
            assertEq(a.confidence, b.confidence, "confidence");
            assertEq(a.valuedAt, b.valuedAt, "valuedAt");
            assertEq(a.writtenAt, b.writtenAt, "writtenAt");
            assertEq(a.cycle, b.cycle, "cycle");
            assertEq(a.data, b.data, "data");
            uint256 lenA = singles.historyLength(prycd, tokenId, kind);
            uint256 lenB = batched.historyLength(prycd, tokenId, kind);
            assertEq(lenA, lenB, "historyLength");
            for (uint256 h; h < lenA; ++h) {
                FabricaFactStore.HistoryEntry memory ha = singles.getHistory(prycd, tokenId, kind, h);
                FabricaFactStore.HistoryEntry memory hb = batched.getHistory(prycd, tokenId, kind, h);
                assertEq(ha.value, hb.value, "history.value");
                assertEq(ha.writtenAt, hb.writtenAt, "history.writtenAt");
                assertEq(ha.cycle, hb.cycle, "history.cycle");
            }
            (FabricaFactStore.Fact memory liveA, bool okA) = singles.getLiveFact(prycd, tokenId, kind);
            (FabricaFactStore.Fact memory liveB, bool okB) = batched.getLiveFact(prycd, tokenId, kind);
            assertEq(okA, okB, "live flag");
            assertEq(liveA.value, liveB.value, "live value");
        }
    }

    function _assertLogParity(Vm.Log[] memory a, Vm.Log[] memory b) internal pure {
        assertEq(a.length, b.length, "log count");
        for (uint256 i; i < a.length; ++i) {
            assertEq(a[i].topics.length, b[i].topics.length, "topic count");
            for (uint256 t; t < a[i].topics.length; ++t) {
                assertEq(a[i].topics[t], b[i].topics[t], "topic");
            }
            assertEq(a[i].data, b[i].data, "log data");
        }
    }

    function _mixedInputs(uint256 n) internal view returns (FabricaFactStore.FactInput[] memory inputs) {
        inputs = new FabricaFactStore.FactInput[](n);
        for (uint256 i; i < n; ++i) {
            // Last input rewrites the first row so history parity is in the comparison, not only live facts.
            uint256 tokenId = i + 1 == n ? TOKEN : TOKEN + i;
            bytes32 kind = tokenId == TOKEN || i % 2 == 0 ? kindPrice : kindAttribute;
            inputs[i] = _input(tokenId, kind, PRICE + uint128(i), CYCLE);
            inputs[i].data = keccak256(abi.encode("eng4203", i));
        }
    }

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
