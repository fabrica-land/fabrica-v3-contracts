// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Test.sol";

import {ForkTestBase} from "./ForkTestBase.sol";
import {FabricaFactStore} from "../src/FabricaFactStore.sol";

/// @notice ENG-3924 — the as-shipped Sepolia sequence, rehearsed on a Sepolia fork.
/// @dev This is the local half of the functional-verification gate. It runs, in order and against
///      real Sepolia state and block time, exactly the four clauses ENG-3924 requires be shown on
///      chain, so the on-chain run is a repeat of a sequence already known to pass rather than a
///      first attempt paid for in real transactions:
///
///        1. two writer addresses each write a fact for the same token, and neither can touch the
///           other's row;
///        2. a writer locks a token and the read reflects it;
///        3. the same writer unlocks and the read recovers;
///        4. a third address trying to lock, unlock or invalidate another writer's facts REVERTS.
///
///      Uses the repo's shared fork harness and the `sepolia` RPC alias from `foundry.toml`, pinned
///      to a fixed block so the run is reproducible, exactly like the other six fork suites. The
///      round-1 store at 0xFfA7535eF090C9193f44399843a05b60808ffC0D is read for a single assertion
///      that this deployment does not disturb it, and is never written.
contract Eng3924FactStoreSepoliaForkTest is ForkTestBase {
    address internal constant ROUND_1_STORE = 0xFfA7535eF090C9193f44399843a05b60808ffC0D;
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;
    /// @notice Pinned so the suite is reproducible; the block this sequence was first proven at.
    uint256 internal constant FORK_BLOCK = 11_634_663;
    uint8 internal constant HISTORY_DEPTH = 48;
    uint64 internal constant CYCLE = 1;
    uint256 internal constant TOKEN = 4388;
    uint128 internal constant PRICE_A = 250_000e6;
    uint128 internal constant PRICE_B = 310_000e6;

    FabricaFactStore internal store;
    bytes32 internal kindPrice;

    address internal writerA;
    address internal writerB;
    address internal stranger;

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
        store = new FabricaFactStore(HISTORY_DEPTH);
        kindPrice = store.KIND_PRICE();
        writerA = makeAddr("eng3924-sepolia-writer-a");
        writerB = makeAddr("eng3924-sepolia-writer-b");
        stranger = makeAddr("eng3924-sepolia-stranger");
    }

    function test_sepoliaSequence_allFourClausesInOrder() public {
        assertEq(block.number, FORK_BLOCK, "fork is pinned");
        console.log("ENG-3924 fork rehearsal at pinned Sepolia block", block.number);
        // --- Clause 1: two writers, one token, isolated rows -----------------------------------
        _write(writerA, PRICE_A);
        _write(writerB, PRICE_B);
        assertEq(store.getFact(writerA, TOKEN, kindPrice).value, PRICE_A, "clause 1: writer A holds its own value");
        assertEq(store.getFact(writerB, TOKEN, kindPrice).value, PRICE_B, "clause 1: writer B holds its own value");
        assertTrue(store.isFactLive(writerA, TOKEN, kindPrice), "clause 1: A live");
        assertTrue(store.isFactLive(writerB, TOKEN, kindPrice), "clause 1: B live");
        // Neither can touch the other's row, shown by the reverting call.
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, writerB, writerA));
        vm.prank(writerA);
        store.writeFact(writerB, _input(1));
        assertEq(store.getFact(writerB, TOKEN, kindPrice).value, PRICE_B, "clause 1: B unchanged by A's attempt");
        // --- Clause 2: a writer locks a token and the read reflects it -------------------------
        vm.prank(writerA);
        store.setLock(writerA, TOKEN, true);
        assertTrue(store.locked(writerA, TOKEN), "clause 2: lock flag set");
        assertFalse(store.isFactLive(writerA, TOKEN, kindPrice), "clause 2: A reads dead while locked");
        assertTrue(store.isFactLive(writerB, TOKEN, kindPrice), "clause 2: B is unaffected by A's lock");
        // --- Clause 3: the same writer unlocks and it recovers ---------------------------------
        vm.prank(writerA);
        store.setLock(writerA, TOKEN, false);
        assertFalse(store.locked(writerA, TOKEN), "clause 3: lock flag cleared");
        assertTrue(store.isFactLive(writerA, TOKEN, kindPrice), "clause 3: A recovers");
        assertEq(store.getFact(writerA, TOKEN, kindPrice).value, PRICE_A, "clause 3: A's value survived the lock");
        // --- Clause 4: a third address cannot lock, unlock or invalidate another's facts --------
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, writerA, stranger));
        vm.prank(stranger);
        store.setLock(writerA, TOKEN, true);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, writerA, stranger));
        vm.prank(stranger);
        store.setLock(writerA, TOKEN, false);
        vm.expectRevert(abi.encodeWithSelector(FabricaFactStore.NotWriter.selector, writerA, stranger));
        vm.prank(stranger);
        store.setMinValidCycle(writerA, CYCLE + 1);
        assertFalse(store.locked(writerA, TOKEN), "clause 4: no lock applied by the stranger");
        assertEq(store.minValidCycle(writerA), 0, "clause 4: no invalidation applied by the stranger");
        assertTrue(store.isFactLive(writerA, TOKEN, kindPrice), "clause 4: A still live after all three attempts");
    }

    function test_sepoliaSequence_cycleCloseIsAWriterStatementCarryingTheCycleNumber() public {
        _write(writerA, PRICE_A);
        assertEq(store.lastCycleClose(writerA).closedAt, 0, "a fact write does not close a cycle");
        vm.prank(writerA);
        store.closeCycle(writerA, CYCLE);
        FabricaFactStore.CycleClose memory close = store.lastCycleClose(writerA);
        assertEq(close.cycle, CYCLE, "the close carries the cycle number");
        assertEq(close.closedAt, uint64(block.timestamp), "and the wall-clock a consumer needs for max silence");
        assertEq(store.lastCycleClose(writerB).closedAt, 0, "closes are per writer");
    }

    function test_round1StoreIsUntouchedByThisDeployment() public view {
        // The round-1 store is a separate deployment that stays live and owned; nothing in ENG-3924
        // writes to it. Assert it is still there and still has its owner, so a reviewer can see the
        // redeploy did not disturb it.
        assertGt(ROUND_1_STORE.code.length, 0, "round-1 store still deployed");
        (bool ok, bytes memory raw) = ROUND_1_STORE.staticcall(abi.encodeWithSignature("owner()"));
        assertTrue(ok, "round-1 store still answers owner()");
        assertTrue(abi.decode(raw, (address)) != address(0), "round-1 store still owned");
        assertTrue(address(store) != ROUND_1_STORE, "the round-2 store is a distinct address");
    }

    function _input(uint128 value) internal view returns (FabricaFactStore.FactInput memory) {
        return FabricaFactStore.FactInput({
            tokenId: TOKEN,
            kind: kindPrice,
            value: value,
            confidence: 7700,
            valuedAt: 0,
            cycle: CYCLE,
            data: keccak256(abi.encode("eng3924-sepolia", value))
        });
    }

    function _write(address writer, uint128 value) internal {
        vm.prank(writer);
        store.writeFact(writer, _input(value));
    }
}
