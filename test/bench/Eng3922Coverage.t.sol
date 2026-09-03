// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Eng3922HarnessBase} from "./Eng3922HarnessBase.sol";
import {BenchAggregatorBase} from "./BenchAggregatorBase.sol";
import {ArmOwnerlessStore} from "./arms/ArmOwnerlessStore.sol";
import {ArmEasPointer} from "./arms/ArmEasPointer.sol";
import {ArmEasContext} from "./arms/ArmEasContext.sol";
import {ArmEasIndexer} from "./arms/ArmEasIndexer.sol";

/// @notice ENG-3922 — what each candidate coverage rule costs inside `price()`, per arm.
/// @dev Round 2 uses `None`: Tim ruled at 18:47Z that coverage is immediate supersession, which is
///      the lock leg. The other three are measured because they are round-3 candidates and the
///      numbers cost nothing to keep. One contract per rule, one measurement per test function.
abstract contract Eng3922CoverageBase is Eng3922HarnessBase {
    uint256 internal tokenId;
    bytes internal ctx;

    function _mode() internal pure virtual returns (BenchAggregatorBase.CoverageMode);

    function _tag() internal pure virtual returns (string memory);

    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        tokenId = uint256(keccak256(abi.encode("eng3922-coverage", _tag())));
        _seed(tokenId, 0);
        ctx = _contextFor(tokenId);
    }

    function test_coverageArm3OwnerlessStore() public {
        if (!forked) vm.skip(true);
        _rowAllowIneligible(
            string.concat("arm3 ownerless store    coverage=", _tag()),
            new ArmOwnerlessStore(_cfg(_mode()), address(ownerlessStore), writers),
            tokenId,
            ctx
        );
    }

    function test_coverageArm2EasPointer() public {
        if (!forked) vm.skip(true);
        _rowAllowIneligible(
            string.concat("arm2 EAS+pointer        coverage=", _tag()),
            new ArmEasPointer(_cfg(_mode()), _easCfg(true), address(pointer)),
            tokenId,
            ctx
        );
    }

    function test_coverageArm1cEasContext() public {
        if (!forked) vm.skip(true);
        _rowAllowIneligible(
            string.concat("arm1C EAS oracleContext coverage=", _tag()),
            new ArmEasContext(_cfg(_mode()), _easCfg(true)),
            tokenId,
            ctx
        );
    }

    function test_coverageArm1EasIndexer() public {
        if (!forked) vm.skip(true);
        _rowAllowIneligible(
            string.concat("arm1 all-EAS indexer    coverage=", _tag()),
            new ArmEasIndexer(_cfg(_mode()), _easCfg(true), EAS_INDEXER),
            tokenId,
            ctx
        );
    }

    function test_coverageCalibrationRound1Store() public {
        if (!forked) vm.skip(true);
        _rowAllowIneligible(
            string.concat("cal. round-1 store      coverage=", _tag()), _newArmCustom(_mode()), tokenId, ctx
        );
    }
}

/// @notice Round 2's configuration: no on-chain coverage check.
contract Eng3922CoverageNoneTest is Eng3922CoverageBase {
    function _mode() internal pure override returns (BenchAggregatorBase.CoverageMode) {
        return BenchAggregatorBase.CoverageMode.None;
    }

    function _tag() internal pure override returns (string memory) {
        return "none";
    }
}

contract Eng3922CoverageClosedCycleTest is Eng3922CoverageBase {
    function _mode() internal pure override returns (BenchAggregatorBase.CoverageMode) {
        return BenchAggregatorBase.CoverageMode.ClosedCycle;
    }

    function _tag() internal pure override returns (string memory) {
        return "closedCycle";
    }
}

contract Eng3922CoverageProofAtReadTest is Eng3922CoverageBase {
    function _mode() internal pure override returns (BenchAggregatorBase.CoverageMode) {
        return BenchAggregatorBase.CoverageMode.ProofAtRead;
    }

    function _tag() internal pure override returns (string memory) {
        return "proofAtRead";
    }
}

contract Eng3922CoverageStampTest is Eng3922CoverageBase {
    function _mode() internal pure override returns (BenchAggregatorBase.CoverageMode) {
        return BenchAggregatorBase.CoverageMode.CoverageStamp;
    }

    function _tag() internal pure override returns (string memory) {
        return "coverageStamp";
    }
}
