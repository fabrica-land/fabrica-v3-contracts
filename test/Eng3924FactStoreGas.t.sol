// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {FabricaFactStore} from "../src/FabricaFactStore.sol";

/// @notice ENG-3924 — whole-transaction gas for the round-2 fact store.
/// @dev ENG-3922 measured the arm-3 PROTOTYPE at 74,949 gas per fact. That number does not carry
///      over and must not be quoted for this contract: the prototype refreshed the writer's
///      heartbeat on every price write, and `writeFact` here does not (a cycle close is a separate
///      statement), while every mutating function gained an explicit `writer` calldata word.
///
///      Per the repo gas guard: one scenario per test function, state primed before the
///      measurement, and the result reported whole-transaction (21,000 intrinsic + EIP-2028
///      calldata + execution) rather than execution alone. Run WITHOUT `--gas-report`, whose
///      inspector perturbs the `gasleft()` deltas this bench reads:
///        forge test --match-contract Eng3924FactStoreGasTest -vv
///
///      Every figure here is cross-checked against a real Sepolia receipt in
///      `deployment-artifacts/ENG-3924-round2-fact-store.md`. A cheatcode-simulated number that no
///      receipt agrees with is not evidence, and the first version of this bench was wrong by
///      ~61,500 gas per write in exactly that way.
contract Eng3924FactStoreGasTest is Test {
    uint8 internal constant HISTORY_DEPTH = 48;
    uint64 internal constant CYCLE = 100;
    uint256 internal constant TOKEN = 4388;
    uint128 internal constant PRICE = 250_000e6;
    uint256 internal constant INTRINSIC = 21_000;

    FabricaFactStore internal store;
    bytes32 internal kindPrice;
    address internal writer = makeAddr("eng3924-gas-writer");

    function setUp() public {
        store = new FabricaFactStore(HISTORY_DEPTH);
        kindPrice = store.KIND_PRICE();
        vm.warp(1_788_000_000);
    }

    function test_gas_write1_freshRowPushesNoHistory() public {
        _report("writeFact regime 1 (fresh row, no history push)", _measureWrite(PRICE, CYCLE));
    }

    function test_gas_write2_coldHistorySlotAndColdCounter() public {
        _seedWrites(1);
        _report("writeFact regime 2 (cold history slot + cold counter)", _measureWrite(PRICE + 1, CYCLE));
    }

    function test_gas_write3to48_coldHistorySlotOnly() public {
        _seedWrites(2);
        _report("writeFact regime 3-48 (cold history slot, warm counter)", _measureWrite(PRICE + 2, CYCLE));
    }

    function test_gas_write49plus_ringOverwrite() public {
        _seedWrites(uint128(HISTORY_DEPTH) + 1);
        _report("writeFact regime 49+ (ring overwrite)", _measureWrite(PRICE + HISTORY_DEPTH + 1, CYCLE));
    }

    function test_gas_closeCycle_firstClose() public {
        _report(
            "closeCycle (first close, cold slot)",
            _measureCall(abi.encodeCall(FabricaFactStore.closeCycle, (writer, CYCLE)))
        );
    }

    function test_gas_closeCycle_subsequentClose() public {
        vm.prank(writer);
        store.closeCycle(writer, CYCLE);
        vm.warp(block.timestamp + 1 days);
        _report(
            "closeCycle (subsequent close, warm slot)",
            _measureCall(abi.encodeCall(FabricaFactStore.closeCycle, (writer, CYCLE + 1)))
        );
    }

    function test_gas_setLock_lock() public {
        _seedWrites(1);
        _report(
            "setLock (lock, cold slot)", _measureCall(abi.encodeCall(FabricaFactStore.setLock, (writer, TOKEN, true)))
        );
    }

    function test_gas_setMinValidCycle_bulkInvalidation() public {
        _seedWrites(1);
        _report(
            "setMinValidCycle (kills every fact below the floor)",
            _measureCall(abi.encodeCall(FabricaFactStore.setMinValidCycle, (writer, CYCLE + 1)))
        );
    }

    function test_gas_getLiveFact_readOneRow() public {
        _seedWrites(1);
        vm.cool(address(store));
        uint256 warmTheAccount = address(store).balance;
        warmTheAccount;
        uint256 before = gasleft();
        store.getLiveFact(writer, TOKEN, kindPrice);
        uint256 readGas = before - gasleft();
        // A view call, so no intrinsic and no calldata are added: this is what an aggregator pays
        // inside its own `price()`, which is what ENG-3922 compared across the arms.
        _report("getLiveFact (cold, execution only, as read inside price())", readGas);
    }

    /// @notice Per-fact cost across a run of fresh rows, the unit ENG-3922's write-side table used.
    /// @dev ENG-3922 reported 74,949 gas per fact for arm 3 from a 20-token x 3-source cycle driven
    ///      through `writePriceBatch`, where one transaction's intrinsic cost and one cycle close
    ///      amortise over 60 facts. Round 2 ships NO batch write (round-2 proposal Part A item 12 is
    ///      a round-3 candidate), so a round-2 cycle is one transaction per fact and the per-fact
    ///      cost is the whole single-write transaction. Measured directly so the two numbers are
    ///      never compared as if they shared a unit.
    function test_gas_cycleProjection_freshRowsOneTransactionPerFact() public {
        uint256 facts = 60;
        uint256 total;
        // uint128 counter: `facts` is 60, so the value offset needs no narrowing cast.
        for (uint128 i; i < facts; ++i) {
            FabricaFactStore.FactInput memory input = _input(PRICE + i, CYCLE);
            input.tokenId = TOKEN + i;
            total += _measureCall(abi.encodeCall(FabricaFactStore.writeFact, (writer, input)));
        }
        uint256 perFact = total / facts;
        _report("cycle projection, fresh rows, per fact (one tx per fact)", perFact);
        _report("cycle projection, 1,000 tokens x 3 oracle sources = 3,000 facts", perFact * 3_000);
    }

    /// @notice Whole-transaction gas for one call, measured the way a real transaction pays for it.
    /// @dev Two corrections over the first version of this bench, each of which inflated every row,
    ///      and both caught only because real Sepolia receipts existed to disagree with them.
    ///
    ///      1. `vm.cool` marks the account AND all of its storage slots cold, but a real transaction
    ///         begins with `tx.to` already warm under EIP-2929 while its storage slots are still
    ///         cold. The account is therefore re-warmed with a `BALANCE` read — which touches no
    ///         storage — before the window opens, reproducing exactly the real access pattern.
    ///         Cooling without re-warming billed a spurious cold-account access (~2,500) per row.
    ///      2. The EIP-2028 calldata cost is computed BEFORE the window. In the first version
    ///         `_calldataGas(data)` shared an expression with the closing `gasleft()`, and Solidity
    ///         does not define operand order within an expression: that helper's own ~260-iteration
    ///         loop ran INSIDE the measured window and was billed to the call under test, which is
    ///         where ~58,000 of the ~61,500 per-write overstatement came from.
    function _measureCall(bytes memory callData) internal returns (uint256) {
        uint256 calldataGas = _calldataGas(callData);
        vm.cool(address(store));
        // BALANCE warms the account without warming any storage slot: the real tx.to pattern.
        uint256 warmTheAccount = address(store).balance;
        warmTheAccount;
        vm.prank(writer);
        uint256 before = gasleft();
        (bool ok,) = address(store).call(callData);
        uint256 executionGas = before - gasleft();
        require(ok, "measured call reverted");
        return executionGas + INTRINSIC + calldataGas;
    }

    function _measureWrite(uint128 value, uint64 cycle) internal returns (uint256) {
        return _measureCall(abi.encodeCall(FabricaFactStore.writeFact, (writer, _input(value, cycle))));
    }

    /// @dev Seeds `count` prior writes so the measured call lands in a known ring regime. Each one
    ///      varies `data`, because a repeated provenance word is a no-op store and would understate
    ///      the write that follows it.
    function _seedWrites(uint128 count) internal {
        for (uint128 i; i < count; ++i) {
            FabricaFactStore.FactInput memory input = _input(PRICE + i, CYCLE);
            vm.prank(writer);
            store.writeFact(writer, input);
        }
    }

    function _input(uint128 value, uint64 cycle) internal view returns (FabricaFactStore.FactInput memory) {
        return FabricaFactStore.FactInput({
            tokenId: TOKEN,
            kind: kindPrice,
            value: value,
            confidence: 7700,
            valuedAt: 0,
            cycle: cycle,
            data: keccak256(abi.encode("eng3924-provenance", value, cycle))
        });
    }

    /// @dev EIP-2028: 4 gas per zero byte, 16 per non-zero byte.
    function _calldataGas(bytes memory data) internal pure returns (uint256 total) {
        for (uint256 i; i < data.length; ++i) {
            total += data[i] == 0 ? 4 : 16;
        }
    }

    function _report(string memory label, uint256 gasUsed) internal pure {
        console.log(string.concat("ENG-3924 gas: ", label, " = "), gasUsed);
    }
}
