// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Eng3922HarnessBase} from "./Eng3922HarnessBase.sol";
import {
    IEAS,
    IEASIndexer,
    AttestationRequest,
    AttestationRequestData,
    MultiAttestationRequest,
    RevocationRequestData,
    MultiRevocationRequest
} from "./eas/IEAS.sol";
import {FactPointer} from "./FactPointer.sol";
import {OwnerlessFactStore} from "./OwnerlessFactStore.sol";

/// @notice ENG-3922 — the write side, one operation per test function.
/// @dev Whole-transaction gas (21,000 intrinsic + EIP-2028 calldata + execution) per the CLAUDE.md
///      guard, because every number here is a cost. `vm.cool` immediately before each measured
///      call. Batch figures also report per-item.
///
///      Tim, 3 September 16:49Z: EAS batches through `multiAttest`/`multiRevoke` grouped by schema,
///      which saves only per-transaction overhead because every attestation still writes its own
///      record. That is what these numbers test.
contract Eng3922WriteTest is Eng3922HarnessBase {
    uint256 internal constant BATCH_SMALL = 1;
    uint256 internal constant BATCH_MID = 10;
    uint256 internal constant BATCH_LARGE = 100;

    // ---------------------------------------------------------------------
    // EAS attest
    // ---------------------------------------------------------------------

    function test_easMultiAttest1() public {
        _easAttestBatch(BATCH_SMALL);
    }

    function test_easMultiAttest10() public {
        _easAttestBatch(BATCH_MID);
    }

    function test_easMultiAttest100() public {
        _easAttestBatch(BATCH_LARGE);
    }

    function test_easMultiRevoke1() public {
        _easRevokeBatch(BATCH_SMALL);
    }

    function test_easMultiRevoke10() public {
        _easRevokeBatch(BATCH_MID);
    }

    function test_easMultiRevoke100() public {
        _easRevokeBatch(BATCH_LARGE);
    }

    function test_easIndexAttestations1() public {
        _easIndexBatch(BATCH_SMALL);
    }

    function test_easIndexAttestations10() public {
        _easIndexBatch(BATCH_MID);
    }

    function test_easIndexAttestations100() public {
        _easIndexBatch(BATCH_LARGE);
    }

    // ---------------------------------------------------------------------
    // Pointer
    // ---------------------------------------------------------------------

    function test_pointerPointBatch1() public {
        _pointerBatch(BATCH_SMALL);
    }

    function test_pointerPointBatch10() public {
        _pointerBatch(BATCH_MID);
    }

    function test_pointerPointBatch100() public {
        _pointerBatch(BATCH_LARGE);
    }

    // ---------------------------------------------------------------------
    // Ownerless store
    // ---------------------------------------------------------------------

    function test_ownerlessWritePriceBatch1() public {
        _ownerlessBatch(BATCH_SMALL);
    }

    function test_ownerlessWritePriceBatch10() public {
        _ownerlessBatch(BATCH_MID);
    }

    function test_ownerlessWritePriceBatch100() public {
        _ownerlessBatch(BATCH_LARGE);
    }

    // ---------------------------------------------------------------------
    // Cycle close — round 2 carries the cycle number only (Tim, 18:47Z)
    // ---------------------------------------------------------------------

    function test_ownerlessCycleCloseWithoutRoot() public {
        if (!forked) vm.skip(true);
        bytes memory cd = abi.encodeCall(OwnerlessFactStore.heartbeat, (1, bytes32(0)));
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        ownerlessStore.heartbeat(1, bytes32(0));
        _emitCost("arm3 ownerless store, cycle close WITHOUT root (round 2)", g - gasleft(), cd, 1);
    }

    function test_ownerlessCycleCloseWithRoot() public {
        if (!forked) vm.skip(true);
        bytes memory cd = abi.encodeCall(OwnerlessFactStore.heartbeat, (1, keccak256("root")));
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        ownerlessStore.heartbeat(1, keccak256("root"));
        _emitCost("arm3 ownerless store, cycle close WITH root (round-3 item 13)", g - gasleft(), cd, 1);
    }

    function test_easCycleCloseWithoutRoot() public {
        _easCycleCloseCost("EAS arms, cycle close attestation WITHOUT root (round 2)", bytes32(0));
    }

    function test_easCycleCloseWithRoot() public {
        _easCycleCloseCost("EAS arms, cycle close attestation WITH root (round-3 item 13)", keccak256("root"));
    }

    // ---------------------------------------------------------------------
    // Coverage stamp — round-3 candidate, measured at the 100-batch regime
    // ---------------------------------------------------------------------

    function test_ownerlessStampCoverage100() public {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("stamp", BATCH_LARGE);
        bytes memory cd = abi.encodeCall(OwnerlessFactStore.stampCoverage, (ids, 1));
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        ownerlessStore.stampCoverage(ids, 1);
        _emitCost("arm3 ownerless store, stampCoverage batch 100", g - gasleft(), cd, BATCH_LARGE);
    }

    function test_pointerStampCoverage100() public {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("stamp", BATCH_LARGE);
        bytes memory cd = abi.encodeCall(FactPointer.stampCoverage, (ids, 1));
        vm.cool(address(pointer));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        pointer.stampCoverage(ids, 1);
        _emitCost("arm2 pointer, stampCoverage batch 100", g - gasleft(), cd, BATCH_LARGE);
    }

    function test_easCoverageAttestation100() public {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("stamp-eas", BATCH_LARGE);
        AttestationRequestData[] memory data = new AttestationRequestData[](BATCH_LARGE);
        for (uint256 i; i < BATCH_LARGE; ++i) {
            data[i] = AttestationRequestData({
                recipient: address(uint160(ids[i])),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(ids[i], uint64(1)),
                value: 0
            });
        }
        MultiAttestationRequest[] memory req = new MultiAttestationRequest[](1);
        req[0] = MultiAttestationRequest({schema: coverageSchema, data: data});
        bytes memory cd = abi.encodeCall(IEAS.multiAttest, (req));
        vm.cool(EAS);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        eas.multiAttest(req);
        _emitCost("arm1 all-EAS, coverage attestation batch 100", g - gasleft(), cd, BATCH_LARGE);
    }

    // ---------------------------------------------------------------------
    // Helpers — each performs exactly one measured call
    // ---------------------------------------------------------------------

    function _ids(string memory tag, uint256 n) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = _tokenId(abi.encode("eng3922-write", tag, n, i));
        }
    }

    function _easAttestBatch(uint256 n) internal {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("attest", n);
        AttestationRequestData[] memory data = new AttestationRequestData[](n);
        for (uint256 i; i < n; ++i) {
            data[i] = AttestationRequestData({
                recipient: address(uint160(ids[i])),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: _priceData(ids[i], 0, 100_000e6, 1),
                value: 0
            });
        }
        MultiAttestationRequest[] memory req = new MultiAttestationRequest[](1);
        req[0] = MultiAttestationRequest({schema: priceSchema, data: data});
        bytes memory cd = abi.encodeCall(IEAS.multiAttest, (req));
        vm.cool(EAS);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        eas.multiAttest(req);
        _emitCost(string.concat("EAS multiAttest n=", vm.toString(n)), g - gasleft(), cd, n);
    }

    function _easRevokeBatch(uint256 n) internal {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("revoke", n);
        AttestationRequestData[] memory data = new AttestationRequestData[](n);
        for (uint256 i; i < n; ++i) {
            data[i] = AttestationRequestData({
                recipient: address(uint160(ids[i])),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: _priceData(ids[i], 0, 100_000e6, 1),
                value: 0
            });
        }
        MultiAttestationRequest[] memory areq = new MultiAttestationRequest[](1);
        areq[0] = MultiAttestationRequest({schema: priceSchema, data: data});
        vm.prank(writers[0]);
        bytes32[] memory uids = eas.multiAttest(areq);
        RevocationRequestData[] memory rdata = new RevocationRequestData[](n);
        for (uint256 i; i < n; ++i) {
            rdata[i] = RevocationRequestData({uid: uids[i], value: 0});
        }
        MultiRevocationRequest[] memory rreq = new MultiRevocationRequest[](1);
        rreq[0] = MultiRevocationRequest({schema: priceSchema, data: rdata});
        bytes memory cd = abi.encodeCall(IEAS.multiRevoke, (rreq));
        vm.cool(EAS);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        eas.multiRevoke(rreq);
        _emitCost(string.concat("EAS multiRevoke n=", vm.toString(n)), g - gasleft(), cd, n);
    }

    function _easIndexBatch(uint256 n) internal {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("index", n);
        AttestationRequestData[] memory data = new AttestationRequestData[](n);
        for (uint256 i; i < n; ++i) {
            data[i] = AttestationRequestData({
                recipient: address(uint160(ids[i])),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: _priceData(ids[i], 0, 100_000e6, 1),
                value: 0
            });
        }
        MultiAttestationRequest[] memory areq = new MultiAttestationRequest[](1);
        areq[0] = MultiAttestationRequest({schema: priceSchema, data: data});
        vm.prank(writers[0]);
        bytes32[] memory uids = eas.multiAttest(areq);
        bytes memory cd = abi.encodeCall(IEASIndexer.indexAttestations, (uids));
        vm.cool(EAS_INDEXER);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        indexer.indexAttestations(uids);
        _emitCost(string.concat("EAS indexAttestations n=", vm.toString(n)), g - gasleft(), cd, n);
    }

    function _pointerBatch(uint256 n) internal {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("pointer", n);
        bytes32[] memory kinds = new bytes32[](n);
        bytes32[] memory uids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            kinds[i] = keccak256("price");
            uids[i] = keccak256(abi.encode("uid", n, i));
        }
        bytes memory cd = abi.encodeCall(FactPointer.pointBatch, (ids, kinds, uids));
        vm.cool(address(pointer));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        pointer.pointBatch(ids, kinds, uids);
        _emitCost(string.concat("pointer pointBatch n=", vm.toString(n)), g - gasleft(), cd, n);
    }

    function _ownerlessBatch(uint256 n) internal {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("ownerless", n);
        uint128[] memory prices = new uint128[](n);
        uint24[] memory confs = new uint24[](n);
        uint64[] memory valuedAts = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            prices[i] = 100_000e6;
            confs[i] = 9000;
            valuedAts[i] = uint64(block.timestamp);
        }
        bytes memory cd =
            abi.encodeCall(OwnerlessFactStore.writePriceBatch, (ids, prices, confs, valuedAts, 1, bytes32(0)));
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        ownerlessStore.writePriceBatch(ids, prices, confs, valuedAts, 1, bytes32(0));
        _emitCost(string.concat("ownerless writePriceBatch n=", vm.toString(n)), g - gasleft(), cd, n);
    }

    function _easCycleCloseCost(string memory label, bytes32 root) internal {
        if (!forked) vm.skip(true);
        AttestationRequest memory req = AttestationRequest({
            schema: cycleCloseSchema,
            data: AttestationRequestData({
                recipient: writers[0],
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(writers[0], uint64(1), root),
                value: 0
            })
        });
        bytes memory cd = abi.encodeCall(IEAS.attest, (req));
        vm.cool(EAS);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        eas.attest(req);
        _emitCost(label, g - gasleft(), cd, 1);
    }

    // ---------------------------------------------------------------------
    // Arm 1 totals: an EAS record it cannot find is a record it does not have
    // ---------------------------------------------------------------------

    /// @notice The coverage stamp on arm 1, INCLUDING the Indexer write it needs to be findable.
    /// @dev `multiAttest` creates the record; it does not index it. `ArmEasIndexer._coverageUid`
    ///      discovers coverage through `getSchemaAttesterRecipientAttestationUIDs`, so an unindexed
    ///      coverage attestation is invisible to that arm and the stamp may as well not exist.
    ///      Reporting the attest alone understates what arm 1 must actually pay.
    function test_easCoverageAttestationIndexed100() public {
        if (!forked) vm.skip(true);
        uint256 n = BATCH_LARGE;
        uint256[] memory ids = _ids("stamp-eas-indexed", n);
        AttestationRequestData[] memory data = new AttestationRequestData[](n);
        for (uint256 i; i < n; ++i) {
            data[i] = AttestationRequestData({
                recipient: address(uint160(ids[i])),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(ids[i], uint64(1)),
                value: 0
            });
        }
        MultiAttestationRequest[] memory req = new MultiAttestationRequest[](1);
        req[0] = MultiAttestationRequest({schema: coverageSchema, data: data});
        bytes memory attestCd = abi.encodeCall(IEAS.multiAttest, (req));
        vm.cool(EAS);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        bytes32[] memory uids = eas.multiAttest(req);
        uint256 attestExec = g - gasleft();
        bytes memory indexCd = abi.encodeCall(IEASIndexer.indexAttestations, (uids));
        vm.cool(EAS_INDEXER);
        vm.prank(writers[0]);
        g = gasleft();
        indexer.indexAttestations(uids);
        uint256 indexExec = g - gasleft();
        uint256 total = attestExec + _intrinsicGas(attestCd) + indexExec + _intrinsicGas(indexCd);
        emit log_named_uint("arm1 coverage stamp, attest + index, batch 100 -- WHOLE TRANSACTIONS", total);
        emit log_named_uint("arm1 coverage stamp, attest + index, batch 100 -- per item", total / n);
    }

    /// @notice The cycle close on arm 1, INCLUDING its Indexer write.
    /// @dev Same reasoning: `ArmEasIndexer._cycleCloseUid` finds the cycle close through the
    ///      Indexer, so an unindexed cycle close leaves the writer looking permanently silent.
    function test_easCycleCloseIndexed() public {
        if (!forked) vm.skip(true);
        AttestationRequest memory req = AttestationRequest({
            schema: cycleCloseSchema,
            data: AttestationRequestData({
                recipient: writers[0],
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(writers[0], uint64(1), bytes32(0)),
                value: 0
            })
        });
        bytes memory attestCd = abi.encodeCall(IEAS.attest, (req));
        vm.cool(EAS);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        bytes32 uid = eas.attest(req);
        uint256 attestExec = g - gasleft();
        bytes memory indexCd = abi.encodeCall(IEASIndexer.indexAttestation, (uid));
        vm.cool(EAS_INDEXER);
        vm.prank(writers[0]);
        g = gasleft();
        indexer.indexAttestation(uid);
        uint256 indexExec = g - gasleft();
        emit log_named_uint(
            "arm1 cycle close, attest + index -- WHOLE TRANSACTIONS",
            attestExec + _intrinsicGas(attestCd) + indexExec + _intrinsicGas(indexCd)
        );
    }
}
