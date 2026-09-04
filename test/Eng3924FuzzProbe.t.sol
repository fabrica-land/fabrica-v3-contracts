// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaFactStore} from "../src/FabricaFactStore.sol";

contract Eng3924FuzzProbe is Test {
    FabricaFactStore internal store;
    bytes32 internal kind;
    address internal w = makeAddr("w");

    function setUp() public {
        store = new FabricaFactStore(48);
        kind = store.KIND_PRICE();
        vm.warp(1_788_000_000);
    }

    function _in(uint128 v, uint64 c) internal view returns (FabricaFactStore.FactInput memory) {
        return _inAt(4388, v, c);
    }

    function _inAt(uint256 tokenId, uint128 v, uint64 c) internal view returns (FabricaFactStore.FactInput memory) {
        return FabricaFactStore.FactInput(tokenId, kind, v, 0, 0, c, bytes32(0));
    }

    /// Band math must never revert for arithmetic reasons, only via BandExceeded.
    /// @dev `zeroBaseline` forces the first write to zero on a meaningful share of runs. Left to
    ///      chance a uint128 is zero in about 1 run in 3.4e38, and the un-forced version of this
    ///      probe reached the zero baseline in 0 of 256 runs — so it could never have caught the
    ///      band bug that a zero baseline pins the row to zero forever.
    function testFuzz_bandNeverPanics(uint128 first, uint128 second, uint16 up, uint16 down, bool zeroBaseline) public {
        if (zeroBaseline) first = 0;
        down = uint16(bound(down, 0, 10_000));
        vm.startPrank(w);
        store.declarePolicy(w, FabricaFactStore.WriterPolicy(up, down, 0, true));
        store.writeFact(w, _in(first, 1));
        try store.writeFact(w, _in(second, 1)) {
            assertEq(store.getFact(w, 4388, kind).value, second, "accepted write stored exactly");
        } catch (bytes memory err) {
            // Deliberate truncation: the first four bytes of revert data ARE the selector.
            // forge-lint: disable-next-line(unsafe-typecast)
            bytes4 sel = bytes4(err);
            assertEq(sel, FabricaFactStore.BandExceeded.selector, "only BandExceeded may reject");
            // Reaching a zero baseline is not enough to catch the bug it was added for: a
            // zero-baseline rejection IS a BandExceeded, so the assertion above is satisfied by
            // the very behaviour that is wrong. A zero baseline must not reject AT ALL.
            assertTrue(first != 0, "a zero baseline must never reject a write");
        }
        vm.stopPrank();
    }

    /// historyLength must always equal min(supersessions, depth), and every index must be readable.
    function testFuzz_historyRingConsistent(uint8 writes) public {
        writes = uint8(bound(writes, 1, 60));
        vm.startPrank(w);
        for (uint128 i; i < writes; ++i) {
            store.writeFact(w, _in(1e6 + i, 1));
        }
        vm.stopPrank();
        uint128 expected = writes - 1 > 48 ? 48 : uint128(writes) - 1;
        uint128 len = uint128(store.historyLength(w, 4388, kind));
        assertEq(len, expected, "history length");
        // `writes` is bounded to [1, 60] above, so every index and value here fits a uint128 with
        // no narrowing: the loop counter is declared uint128 rather than cast down to one.
        for (uint128 i; i < len; ++i) {
            FabricaFactStore.HistoryEntry memory h = store.getHistory(w, 4388, kind, i);
            assertEq(h.value, 1e6 + (writes - 2 - i), "newest-first ordering holds across wrap");
        }
    }

    /// A stranger can never change any of writer w's observable state.
    /// A stranger can never change any of writer `w`'s observable state.
    /// @dev Two things this test got wrong at first, both the same class of mistake — a fuzz case
    ///      that looks stronger than it is:
    ///      - a bare `vm.expectRevert()` accepts ANY revert, so the test would still have passed if
    ///        these calls started failing for an unrelated reason (arithmetic, a missing row, an
    ///        out-of-gas). It now pins the exact `NotWriter(writer, caller)` payload, which is the
    ///        only revert that actually demonstrates row isolation;
    ///      - the fuzzed `tokenId` was passed to `setLock` but every assertion read the hardcoded
    ///        token, so the fuzzing dimension proved nothing about the row it perturbed. The fact
    ///        is now written AT the fuzzed token and the assertions read that same token.
    function testFuzz_strangerCannotMutate(address stranger, uint256 tokenId, bool lockValue, uint64 floor) public {
        vm.assume(stranger != w);
        vm.prank(w);
        store.writeFact(w, _inAt(tokenId, 1e6, 1));
        bool liveBefore = store.isFactLive(w, tokenId, kind);
        bytes memory refusal = abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, w, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(refusal);
        store.setLock(w, tokenId, lockValue);
        vm.expectRevert(refusal);
        store.setMinValidCycle(w, floor);
        vm.expectRevert(refusal);
        store.closeCycle(w, floor);
        vm.expectRevert(refusal);
        store.writeFact(w, _inAt(tokenId, 2e6, 1));
        vm.stopPrank();
        assertTrue(liveBefore, "the fuzzed row is live before the stranger touches it");
        assertEq(store.isFactLive(w, tokenId, kind), liveBefore, "liveness unchanged at the fuzzed token");
        assertEq(store.getFact(w, tokenId, kind).value, 1e6, "value unchanged at the fuzzed token");
        assertFalse(store.locked(w, tokenId), "no lock applied at the fuzzed token");
        assertEq(store.minValidCycle(w), 0, "floor unchanged");
        assertEq(store.lastCycleClose(w).closedAt, 0, "no cycle close recorded");
    }
}
