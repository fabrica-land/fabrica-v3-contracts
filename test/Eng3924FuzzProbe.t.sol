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
        return FabricaFactStore.FactInput(4388, kind, v, 0, 0, c, bytes32(0));
    }

    /// Band math must never revert for arithmetic reasons, only via BandExceeded.
    function testFuzz_bandNeverPanics(uint128 first, uint128 second, uint16 up, uint16 down) public {
        down = uint16(bound(down, 0, 10_000));
        vm.startPrank(w);
        store.declarePolicy(w, FabricaFactStore.WriterPolicy(up, down, 0, true));
        store.writeFact(w, _in(first, 1));
        try store.writeFact(w, _in(second, 1)) {
            assertEq(store.getFact(w, 4388, kind).value, second, "accepted write stored exactly");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertEq(sel, FabricaFactStore.BandExceeded.selector, "only BandExceeded may reject");
        }
        vm.stopPrank();
    }

    /// historyLength must always equal min(supersessions, depth), and every index must be readable.
    function testFuzz_historyRingConsistent(uint8 writes) public {
        writes = uint8(bound(writes, 1, 60));
        vm.startPrank(w);
        for (uint256 i; i < writes; ++i) {
            store.writeFact(w, _in(uint128(1e6 + i), 1));
        }
        vm.stopPrank();
        uint256 expected = writes - 1 > 48 ? 48 : writes - 1;
        uint256 len = store.historyLength(w, 4388, kind);
        assertEq(len, expected, "history length");
        for (uint256 i; i < len; ++i) {
            FabricaFactStore.HistoryEntry memory h = store.getHistory(w, 4388, kind, i);
            assertEq(h.value, uint128(1e6 + (writes - 2 - i)), "newest-first ordering holds across wrap");
        }
    }

    /// A stranger can never change any of writer w's observable state.
    function testFuzz_strangerCannotMutate(address stranger, uint256 tokenId, bool lockValue, uint64 floor) public {
        vm.assume(stranger != w);
        vm.startPrank(w);
        store.writeFact(w, _in(1e6, 1));
        vm.stopPrank();
        bool liveBefore = store.isFactLive(w, 4388, kind);
        vm.startPrank(stranger);
        vm.expectRevert();
        store.setLock(w, tokenId, lockValue);
        vm.expectRevert();
        store.setMinValidCycle(w, floor);
        vm.expectRevert();
        store.closeCycle(w, floor);
        vm.expectRevert();
        store.writeFact(w, _in(2e6, 1));
        vm.stopPrank();
        assertEq(store.isFactLive(w, 4388, kind), liveBefore, "liveness unchanged");
        assertEq(store.getFact(w, 4388, kind).value, 1e6, "value unchanged");
        assertEq(store.minValidCycle(w), 0, "floor unchanged");
    }
}
