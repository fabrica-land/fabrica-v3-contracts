// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {FabricaFactStore} from "../src/FabricaFactStore.sol";

/// @notice ENG-4203 — whole-transaction gas for `writeFacts` vs the ENG-3924 single-write baseline.
/// @dev Same measurement method the ENG-3924 record settled on after its retraction: `vm.cool`
///      then a BALANCE re-warm so the account is not billed cold, and EIP-2028 calldata cost
///      computed BEFORE the window so the helper loop is not billed to the call under test.
///      Run WITHOUT `--gas-report`:
///        forge test --match-contract Eng4203FactStoreBatchGasTest -vv
contract Eng4203FactStoreBatchGasTest is Test {
    uint8 internal constant HISTORY_DEPTH = 48;
    uint64 internal constant CYCLE = 100;
    uint256 internal constant TOKEN = 4388;
    uint128 internal constant PRICE = 250_000e6;
    uint256 internal constant INTRINSIC = 21_000;
    uint256 internal constant BASELINE_BENCH = 98_668;
    uint256 internal constant BASELINE_RECEIPT = 97_703;

    FabricaFactStore internal store;
    bytes32 internal kindPrice;
    address internal writer = makeAddr("eng4203-gas-writer");

    function setUp() public {
        store = new FabricaFactStore(HISTORY_DEPTH);
        kindPrice = store.KIND_PRICE();
        vm.warp(1_788_000_000);
    }

    function test_gas_writeFact_freshRowBaseline() public {
        _report("writeFact n=1 (ENG-3924 regime 1 baseline)", _measureWriteFact());
    }

    function test_gas_writeFacts_n1() public {
        uint256 g = _measureWriteFacts(1);
        _report("writeFacts n=1 whole-tx", g);
        _report("writeFacts n=1 per fact", g);
    }

    function test_gas_writeFacts_n9() public {
        uint256 g = _measureWriteFacts(9);
        _report("writeFacts n=9 whole-tx", g);
        _report("writeFacts n=9 per fact", g / 9);
    }

    function test_gas_writeFacts_n10() public {
        uint256 g9 = _measureWriteFacts(9);
        uint256 g10 = _measureWriteFacts(10);
        _report("writeFacts n=10 whole-tx", g10);
        _report("writeFacts n=10 per fact (whole-tx/N)", g10 / 10);
        _report("writeFacts n=10 marginal (g10-g9)", g10 - g9);
    }

    function test_gas_writeFacts_n49() public {
        uint256 g = _measureWriteFacts(49);
        _report("writeFacts n=49 whole-tx", g);
        _report("writeFacts n=49 per fact", g / 49);
    }

    function test_gas_writeFacts_n50() public {
        uint256 g49 = _measureWriteFacts(49);
        uint256 g50 = _measureWriteFacts(50);
        _report("writeFacts n=50 whole-tx", g50);
        _report("writeFacts n=50 per fact (whole-tx/N)", g50 / 50);
        _report("writeFacts n=50 marginal (g50-g49)", g50 - g49);
    }

    function test_gas_writeFacts_n99() public {
        uint256 g = _measureWriteFacts(99);
        _report("writeFacts n=99 whole-tx", g);
        _report("writeFacts n=99 per fact", g / 99);
    }

    function test_gas_writeFacts_n100() public {
        uint256 g99 = _measureWriteFacts(99);
        uint256 g100 = _measureWriteFacts(100);
        _report("writeFacts n=100 whole-tx", g100);
        _report("writeFacts n=100 per fact (whole-tx/N)", g100 / 100);
        _report("writeFacts n=100 marginal (g100-g99)", g100 - g99);
        _report("ENG-3924 baseline bench", BASELINE_BENCH);
        _report("ENG-3924 baseline Sepolia receipt", BASELINE_RECEIPT);
    }

    function _measureWriteFact() internal returns (uint256) {
        return _measureCallOn(store, abi.encodeCall(FabricaFactStore.writeFact, (writer, _one(0))));
    }

    function _measureWriteFacts(uint256 n) internal returns (uint256) {
        FabricaFactStore isolated = new FabricaFactStore(HISTORY_DEPTH);
        FabricaFactStore.FactInput[] memory inputs = new FabricaFactStore.FactInput[](n);
        for (uint256 i; i < n; ++i) {
            inputs[i] = _one(i);
        }
        return _measureCallOn(isolated, abi.encodeCall(FabricaFactStore.writeFacts, (writer, inputs)));
    }

    function _measureCallOn(FabricaFactStore target, bytes memory callData) internal returns (uint256) {
        uint256 calldataGas = _calldataGas(callData);
        vm.cool(address(target));
        uint256 warmTheAccount = address(target).balance;
        warmTheAccount;
        vm.prank(writer);
        uint256 before = gasleft();
        (bool ok,) = address(target).call(callData);
        uint256 executionGas = before - gasleft();
        require(ok, "measured call reverted");
        return executionGas + INTRINSIC + calldataGas;
    }

    function _one(uint256 i) internal view returns (FabricaFactStore.FactInput memory) {
        return FabricaFactStore.FactInput({
            tokenId: TOKEN + i,
            kind: kindPrice,
            value: PRICE,
            confidence: 7700,
            valuedAt: 0,
            cycle: CYCLE,
            data: keccak256(abi.encode("eng4203-provenance", i))
        });
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 total) {
        for (uint256 i; i < data.length; ++i) {
            total += data[i] == 0 ? 4 : 16;
        }
    }

    function _report(string memory label, uint256 gasUsed) internal pure {
        console.log(string.concat("ENG-4203 gas: ", label, " = "), gasUsed);
    }
}
