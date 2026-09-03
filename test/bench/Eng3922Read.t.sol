// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Eng3922HarnessBase} from "./Eng3922HarnessBase.sol";
import {BenchAggregatorBase} from "./BenchAggregatorBase.sol";

/// @notice ENG-3922 — the go/no-go: gas inside `price()` for a three-source read, per arm.
/// @dev One measurement per test function, seeding done in `setUp`, per the CLAUDE.md gas guard.
///      One contract per seasoning walk depth so the five arms read identical data at that depth;
///      the depth each arm actually walked is reported alongside the gas rather than assumed from
///      the fixture.
abstract contract Eng3922ReadBase is Eng3922HarnessBase {
    uint256 internal tokenId;
    bytes internal ctx;

    function _walkDepth() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        tokenId = uint256(keccak256(abi.encode("eng3922-read", _walkDepth())));
        _seed(tokenId, _walkDepth());
        ctx = _contextFor(tokenId);
    }

    function test_readArm3OwnerlessStore() public {
        if (!forked) vm.skip(true);
        _row("arm3 ownerless store   ", _armOwnerless(), tokenId, ctx);
    }

    function test_readArm2EasPointer() public {
        if (!forked) vm.skip(true);
        _row("arm2 EAS+pointer       ", _armPointer(true), tokenId, ctx);
    }

    function test_readArm1cEasContext() public {
        if (!forked) vm.skip(true);
        _row("arm1C EAS oracleContext", _armContext(true), tokenId, ctx);
    }

    function test_readArm1EasIndexer() public {
        if (!forked) vm.skip(true);
        _row("arm1 all-EAS indexer   ", _armIndexer(true), tokenId, ctx);
    }

    function test_readCalibrationRound1Store() public {
        if (!forked) vm.skip(true);
        _row("cal. round-1 store     ", _armCustom(), tokenId, ctx);
    }
}

/// @notice Walk depth 0 — the weekly-cycle operating point and the depth the mark is judged at.
contract Eng3922ReadDepth0Test is Eng3922ReadBase {
    function _walkDepth() internal pure override returns (uint256) {
        return 0;
    }
}

contract Eng3922ReadDepth1Test is Eng3922ReadBase {
    function _walkDepth() internal pure override returns (uint256) {
        return 1;
    }
}

contract Eng3922ReadDepth3Test is Eng3922ReadBase {
    function _walkDepth() internal pure override returns (uint256) {
        return 3;
    }
}

contract Eng3922ReadDepth7Test is Eng3922ReadBase {
    function _walkDepth() internal pure override returns (uint256) {
        return 7;
    }
}

/// @notice What rebuilding EAS's missing per-writer heartbeat costs, isolated.
/// @dev EAS has no dead-man switch on the attester. Two test functions, one measurement each.
contract Eng3922HeartbeatCostTest is Eng3922HarnessBase {
    uint256 internal tokenId;
    bytes internal ctx;

    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        tokenId = uint256(keccak256("eng3922-heartbeat-cost"));
        _seed(tokenId, 0);
        ctx = _contextFor(tokenId);
    }

    function test_arm2WithRebuiltHeartbeat() public {
        if (!forked) vm.skip(true);
        emit log_named_uint("arm2 price() WITH rebuilt per-writer heartbeat", _measure(_armPointer(true), tokenId, ctx));
    }

    function test_arm2WithoutHeartbeat() public {
        if (!forked) vm.skip(true);
        emit log_named_uint(
            "arm2 price() WITHOUT heartbeat (freshness from attestation time only)",
            _measure(_armPointer(false), tokenId, ctx)
        );
    }
}

/// @notice Arm 1's read cost as a function of how many attestations have accumulated in an
///         Indexer row — the one arm whose read is not O(1) in its own write history.
/// @dev Found by disagreement rather than by design: the second Sepolia run re-published the same
///      token ids, so each `(schema, attester, recipient)` Indexer row held two attestations
///      instead of one, and arm 1's on-chain read came out 4.6% above the fork while every other
///      arm agreed to within 0.9%. Extra attestations here carry `refUID = 0`, so the seasoning
///      walk stays at depth 0 and the ONLY thing changing is how deep the Indexer row is.
abstract contract Eng3922IndexerRowDepthBase is Eng3922HarnessBase {
    uint256 internal tokenId;

    function _extraAttestations() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        tokenId = uint256(keccak256(abi.encode("eng3922-rowdepth", _extraAttestations())));
        _seed(tokenId, 0);
        for (uint256 n; n < _extraAttestations(); ++n) {
            for (uint8 s; s < 3; ++s) {
                _easPublishUnchained(s, tokenId, uint128(100_000e6 + (n + 1) * 10e6));
            }
        }
    }

    function test_indexerRowDepthReadGas() public {
        if (!forked) vm.skip(true);
        emit log_named_uint(
            string.concat("arm1 all-EAS indexer, Indexer row depth ", vm.toString(_extraAttestations() + 1)),
            _measure(_armIndexer(true), tokenId, _contextFor(tokenId))
        );
    }
}

contract Eng3922IndexerRowDepth1Test is Eng3922IndexerRowDepthBase {
    function _extraAttestations() internal pure override returns (uint256) {
        return 0;
    }
}

contract Eng3922IndexerRowDepth2Test is Eng3922IndexerRowDepthBase {
    function _extraAttestations() internal pure override returns (uint256) {
        return 1;
    }
}

contract Eng3922IndexerRowDepth5Test is Eng3922IndexerRowDepthBase {
    function _extraAttestations() internal pure override returns (uint256) {
        return 4;
    }
}
