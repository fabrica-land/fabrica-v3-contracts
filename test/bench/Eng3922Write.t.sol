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
/// @dev RUNTIME (ENG-3964): this file now takes roughly 6-8 minutes, against ~160ms before. The
///      cost is the n>=200 batches added for ENG-3964 item 3, which locate the block-gas-limit
///      boundary by MEASURING adjacent batch sizes rather than dividing a per-item figure by the
///      limit. The intermediate search rows (200/225/250/350) are kept deliberately: they are what
///      makes n_max reproducible instead of asserted. A reviewer re-running this should budget the
///      minutes rather than assume a hang.
///
///      SEARCH METHOD for n_max, so the boundary can be re-derived: step multiAttest at 200, 225,
///      230 against the 60,000,000 mainnet block gas limit the page reads from chain, then measure
///      the decisive ADJACENT PAIR — 230 fits at 59,899,669 (99.83% of a block) and 231 does not at
///      60,161,620 (100.27%). The lookup legs are checked at the same size and neither binds
///      (indexAttestations 38,077,042 = 63.5%, pointBatch 6,119,762 = 10.2%), so both EAS arms'
///      ceiling is the attest leg. A projection from the n=100 per-item figure gave 231 and was one
///      out, which is why the pair is measured.
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
    // ENG-3964 item 1+2 — the cycle close a writer pays the FIRST time
    //
    // The bespoke store has a measured cold-slot bootstrap (heartbeat first 34,153 gas dearer than
    // repeat). ENG-3944 excluded the EAS equivalent as unmeasured. It is measured here, and it is
    // NOT where the ticket assumed: `setUp` attests nothing under the cycle-close schema and
    // Foundry re-runs `setUp` per test, so the close attestation already measured at 235,993 is
    // itself a writer's FIRST. The attestation is flat because EAS writes each attestation to a
    // fresh uid slot and keeps no per-attester state on the direct `attest` path.
    //
    // The bootstrap premium therefore lives entirely in the LOOKUP write, which is per-row:
    //   arm 1 — the Indexer array for (cycleCloseSchema, writer, writer): first entry initialises
    //           the array, later entries append.
    //   arm 2 — `_head[writer][0][KIND_CYCLE_CLOSE]`: first write is a zero -> non-zero SSTORE,
    //           later writes overwrite a non-zero slot.
    // Both are measured first AND repeat, so the premium is a difference of two measured rows
    // rather than an assertion about storage rules.
    //
    // COOLING: each pair cools EVERY address its measured call touches -- EAS, the SchemaRegistry
    // it reads the schema from, and the Indexer or pointer being written -- in BOTH halves. Cooling
    // only the contract under test leaves the priming call's other reads warm, and the first/repeat
    // delta then contains harness warmth as well as the row's own cold-slot cost. Measured both
    // ways while writing this: cooling EAS alone reported the attestation premium 16,945 gas dearer
    // than it is.
    // ---------------------------------------------------------------------

    /// @dev Arm 2 finds its close through `pointer.headOf(writer, 0, KIND_CYCLE_CLOSE)`
    ///      (`ArmEasPointer._cycleCloseUid`), so tokenId 0 and that kind are the row.
    bytes32 internal constant KIND_CYCLE_CLOSE = keccak256("cycleClose");

    function test_easCycleCloseAttestFirst() public {
        if (!forked) vm.skip(true);
        AttestationRequest memory req = _easCloseRequest(1);
        bytes memory cd = abi.encodeCall(IEAS.attest, (req));
        _coolAttestPath();
        vm.prank(writers[0]);
        uint256 g = gasleft();
        eas.attest(req);
        _emitCost("EAS arms, cycle close attestation FIRST by the writer", g - gasleft(), cd, 1);
    }

    function test_easCycleCloseAttestSecond() public {
        if (!forked) vm.skip(true);
        _easCloseAttest(1);
        AttestationRequest memory req = _easCloseRequest(2);
        bytes memory cd = abi.encodeCall(IEAS.attest, (req));
        _coolAttestPath();
        vm.prank(writers[0]);
        uint256 g = gasleft();
        eas.attest(req);
        _emitCost("EAS arms, cycle close attestation SECOND by the same writer", g - gasleft(), cd, 1);
    }

    function test_easCycleCloseIndexFirst() public {
        if (!forked) vm.skip(true);
        bytes32 uid = _easCloseAttest(1);
        bytes memory cd = abi.encodeCall(IEASIndexer.indexAttestation, (uid));
        _coolAttestPath();
        vm.cool(EAS_INDEXER);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        indexer.indexAttestation(uid);
        _emitCost("arm1 cycle close, Indexer write FIRST on the row", g - gasleft(), cd, 1);
    }

    function test_easCycleCloseIndexRepeat() public {
        if (!forked) vm.skip(true);
        bytes32 first = _easCloseAttest(1);
        vm.prank(writers[0]);
        indexer.indexAttestation(first);
        bytes32 second = _easCloseAttest(2);
        bytes memory cd = abi.encodeCall(IEASIndexer.indexAttestation, (second));
        _coolAttestPath();
        vm.cool(EAS_INDEXER);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        indexer.indexAttestation(second);
        _emitCost("arm1 cycle close, Indexer write REPEAT on the row", g - gasleft(), cd, 1);
    }

    function test_pointerCycleCloseFirst() public {
        if (!forked) vm.skip(true);
        bytes32 uid = _easCloseAttest(1);
        bytes memory cd = abi.encodeCall(FactPointer.point, (0, KIND_CYCLE_CLOSE, uid));
        _coolAttestPath();
        vm.cool(address(pointer));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        pointer.point(0, KIND_CYCLE_CLOSE, uid);
        _emitCost("arm2 cycle close, pointer write FIRST on the row", g - gasleft(), cd, 1);
    }

    function test_pointerCycleCloseRepeat() public {
        if (!forked) vm.skip(true);
        bytes32 first = _easCloseAttest(1);
        vm.prank(writers[0]);
        pointer.point(0, KIND_CYCLE_CLOSE, first);
        bytes32 second = _easCloseAttest(2);
        bytes memory cd = abi.encodeCall(FactPointer.point, (0, KIND_CYCLE_CLOSE, second));
        _coolAttestPath();
        vm.cool(address(pointer));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        pointer.point(0, KIND_CYCLE_CLOSE, second);
        _emitCost("arm2 cycle close, pointer write REPEAT on the row", g - gasleft(), cd, 1);
    }

    function _easCloseRequest(uint64 cycle) internal view returns (AttestationRequest memory) {
        return AttestationRequest({
            schema: cycleCloseSchema,
            data: AttestationRequestData({
                recipient: writers[0],
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(writers[0], cycle, bytes32(0)),
                value: 0
            })
        });
    }

    /// @dev Every address an EAS write touches: the entry point and the registry it reads the
    ///      schema from. Cooled together so a priming call leaves nothing warm behind it.
    function _coolAttestPath() internal {
        vm.cool(EAS);
        vm.cool(SCHEMA_REGISTRY);
    }

    function _easCloseAttest(uint64 cycle) internal returns (bytes32) {
        vm.prank(writers[0]);
        return eas.attest(_easCloseRequest(cycle));
    }

    // ---------------------------------------------------------------------
    // ENG-3964 item 4 — attribute writes on EAS
    //
    // ENG-3944 excluded the attribute term on the EAS dial because no attribute attestation had
    // been measured. It is measured here under the same additive rule the price term uses: a
    // record the arm cannot find is a record it does not have, so an attribute write is the
    // attestation PLUS the write that makes it findable — the Indexer on arm 1, the pointer on
    // arm 2. The arms read no attributes today (the attributes dial is a write-side term only),
    // so the lookup write is charged structurally rather than because an arm's read path calls it.
    //
    // The lookup row is per (token, attribute), so a token's FIRST attribute write pays a cold row
    // and later ones do not — the same shape the bespoke store has (writeAttribute first 146,271
    // against repeat 58,094). Both regimes are measured at the 100 batch so the model can charge
    // the first write and the rest apart, exactly as it does on the bespoke layer.
    // ---------------------------------------------------------------------

    bytes32 internal constant KIND_ATTRIBUTE = keccak256("attribute");

    function test_easAttributeAttest1() public {
        _easAttributeAttestBatch(BATCH_SMALL);
    }

    function test_easAttributeAttest10() public {
        _easAttributeAttestBatch(BATCH_MID);
    }

    function test_easAttributeAttest100() public {
        _easAttributeAttestBatch(BATCH_LARGE);
    }

    function test_easAttributeIndex1() public {
        _easAttributeIndexBatch(BATCH_SMALL, false);
    }

    function test_easAttributeIndex10() public {
        _easAttributeIndexBatch(BATCH_MID, false);
    }

    function test_easAttributeIndex100() public {
        _easAttributeIndexBatch(BATCH_LARGE, false);
    }

    function test_easAttributeIndexRepeat1() public {
        _easAttributeIndexBatch(BATCH_SMALL, true);
    }

    function test_easAttributeIndexRepeat10() public {
        _easAttributeIndexBatch(BATCH_MID, true);
    }

    function test_easAttributeIndexRepeat100() public {
        _easAttributeIndexBatch(BATCH_LARGE, true);
    }

    function test_easAttributePoint1() public {
        _easAttributePointBatch(BATCH_SMALL, false);
    }

    function test_easAttributePoint10() public {
        _easAttributePointBatch(BATCH_MID, false);
    }

    function test_easAttributePoint100() public {
        _easAttributePointBatch(BATCH_LARGE, false);
    }

    function test_easAttributePointRepeat1() public {
        _easAttributePointBatch(BATCH_SMALL, true);
    }

    function test_easAttributePointRepeat10() public {
        _easAttributePointBatch(BATCH_MID, true);
    }

    function test_easAttributePointRepeat100() public {
        _easAttributePointBatch(BATCH_LARGE, true);
    }

    // The dial-1,000 decomposition, for the attribute stream as well as the price stream. 230 is
    // the PRICE arm's measured ceiling; the attribute legs fit comfortably at that size (the
    // attribute attestation is the cheaper of the two schemas), so the same 4 x 230 + 80 split is
    // used for both streams and the two remain comparable on one dial.

    function test_easAttributeAttest230() public {
        _easAttributeAttestBatch(230);
    }

    function test_easAttributeAttest80() public {
        _easAttributeAttestBatch(80);
    }

    function test_easAttributeIndex230() public {
        _easAttributeIndexBatch(230, false);
    }

    function test_easAttributeIndex80() public {
        _easAttributeIndexBatch(80, false);
    }

    function test_easAttributeIndexRepeat230() public {
        _easAttributeIndexBatch(230, true);
    }

    function test_easAttributeIndexRepeat80() public {
        _easAttributeIndexBatch(80, true);
    }

    function test_easAttributePoint230() public {
        _easAttributePointBatch(230, false);
    }

    function test_easAttributePoint80() public {
        _easAttributePointBatch(80, false);
    }

    function test_easAttributePointRepeat230() public {
        _easAttributePointBatch(230, true);
    }

    function test_easAttributePointRepeat80() public {
        _easAttributePointBatch(80, true);
    }

    function _attributeData(uint256 tokenId, uint256 i) internal pure returns (bytes memory) {
        // Values must VARY between writes, per the repo's provenance-hash guard: a repeated value
        // is a no-op store at 100 gas instead of a real one and would understate every repeat.
        return abi.encode(tokenId, keccak256(abi.encode("attr", i)), keccak256(abi.encode("value", tokenId, i)));
    }

    function _easAttributeRequests(uint256[] memory ids, uint256 salt)
        internal
        view
        returns (MultiAttestationRequest[] memory req)
    {
        AttestationRequestData[] memory data = new AttestationRequestData[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            data[i] = AttestationRequestData({
                recipient: address(uint160(ids[i])),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: _attributeData(ids[i], salt),
                value: 0
            });
        }
        req = new MultiAttestationRequest[](1);
        req[0] = MultiAttestationRequest({schema: attributeSchema, data: data});
    }

    function _easAttributeAttestBatch(uint256 n) internal {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("attr-attest", n);
        MultiAttestationRequest[] memory req = _easAttributeRequests(ids, 0);
        bytes memory cd = abi.encodeCall(IEAS.multiAttest, (req));
        _coolAttestPath();
        vm.prank(writers[0]);
        uint256 g = gasleft();
        eas.multiAttest(req);
        _emitCost(string.concat("EAS attribute multiAttest n=", vm.toString(n)), g - gasleft(), cd, n);
    }

    function _easAttributeIndexBatch(uint256 n, bool repeat) internal {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("attr-index", n);
        if (repeat) {
            vm.prank(writers[0]);
            bytes32[] memory warm = eas.multiAttest(_easAttributeRequests(ids, 1));
            vm.prank(writers[0]);
            indexer.indexAttestations(warm);
        }
        vm.prank(writers[0]);
        bytes32[] memory uids = eas.multiAttest(_easAttributeRequests(ids, 2));
        bytes memory cd = abi.encodeCall(IEASIndexer.indexAttestations, (uids));
        _coolAttestPath();
        vm.cool(EAS_INDEXER);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        indexer.indexAttestations(uids);
        _emitCost(
            string.concat(
                "EAS attribute indexAttestations n=",
                vm.toString(n),
                repeat ? " REPEAT on the row" : " FIRST on the row"
            ),
            g - gasleft(),
            cd,
            n
        );
    }

    function _easAttributePointBatch(uint256 n, bool repeat) internal {
        if (!forked) vm.skip(true);
        uint256[] memory ids = _ids("attr-point", n);
        bytes32[] memory kinds = new bytes32[](n);
        bytes32[] memory uids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            kinds[i] = KIND_ATTRIBUTE;
            uids[i] = keccak256(abi.encode("attr-uid", n, i, repeat));
        }
        if (repeat) {
            bytes32[] memory prior = new bytes32[](n);
            for (uint256 i; i < n; ++i) {
                prior[i] = keccak256(abi.encode("attr-uid-prior", n, i));
            }
            vm.prank(writers[0]);
            pointer.pointBatch(ids, kinds, prior);
        }
        bytes memory cd = abi.encodeCall(FactPointer.pointBatch, (ids, kinds, uids));
        vm.cool(address(pointer));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        pointer.pointBatch(ids, kinds, uids);
        _emitCost(
            string.concat(
                "EAS attribute pointBatch n=", vm.toString(n), repeat ? " REPEAT on the row" : " FIRST on the row"
            ),
            g - gasleft(),
            cd,
            n
        );
    }

    // ---------------------------------------------------------------------
    // ENG-3964 item 3 — the batch dial at 1,000
    //
    // The dial offers 1,000 and the EAS write side was measured only to 100, so ENG-3944 dashed the
    // card. A single n=1,000 attestation is not the answer: it does not fit in a block. The mainnet
    // block gas limit the page reads from chain is 60,000,000, and these rows locate the real
    // boundary by MEASURING at candidate sizes rather than dividing a per-item figure by the limit.
    //
    // What the page then charges at dial 1,000 is a composition of measured rows: ceil(1000 / nMax)
    // transactions, being k full batches of nMax plus one residual batch, each a measured row. No
    // extrapolation enters the figure.
    // ---------------------------------------------------------------------

    uint256 internal constant BLOCK_GAS_LIMIT = 60_000_000;

    function test_easMultiAttest200() public {
        _easAttestBatch(200);
    }

    function test_easMultiAttest225() public {
        _easAttestBatch(225);
    }

    function test_easMultiAttest230() public {
        _easAttestBatch(230);
    }

    function test_easMultiAttest231() public {
        _easAttestBatch(231);
    }

    function test_easMultiAttest250() public {
        _easAttestBatch(250);
    }

    /// @dev The residual batch for dial 1,000: 1000 = 4 x 230 + 80.
    function test_easMultiAttest80() public {
        _easAttestBatch(80);
    }

    function test_easIndexAttestations230() public {
        _easIndexBatch(230);
    }

    function test_easIndexAttestations80() public {
        _easIndexBatch(80);
    }

    function test_pointerPointBatch230() public {
        _pointerBatch(230);
    }

    function test_pointerPointBatch80() public {
        _pointerBatch(80);
    }

    function test_easIndexAttestations200() public {
        _easIndexBatch(200);
    }

    function test_easIndexAttestations350() public {
        _easIndexBatch(350);
    }

    function test_pointerPointBatch200() public {
        _pointerBatch(200);
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
        // `attest` reads the schema from the registry, which `setUp` leaves warm. Cooling EAS alone
        // charged that read at warm prices on every row this helper emits.
        _coolAttestPath();
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
        // The index write reads every attestation back out of EAS, which the priming multiAttest
        // above leaves warm. Cool both, as the pair helpers do.
        _coolAttestPath();
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
