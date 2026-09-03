// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BenchAggregatorBase} from "../BenchAggregatorBase.sol";
import {IEAS, Attestation} from "../eas/IEAS.sol";

/// @notice Everything the three EAS arms share: validation, the `refUID` walk, and the lock.
/// @dev The arms differ in exactly one thing — how the aggregator obtains the head uid for a
///      (writer, tokenId) row. That is EAS's keying gap, and it is the whole question the
///      experiment is asking, so it is the only virtual left.
///
///      Validation is the hard validation Option C requires, and it is applied on EVERY arm,
///      not only the caller-supplied one. On the pointer and indexer arms it is redundant but
///      nearly free, and running it everywhere keeps the arms' gas comparable rather than
///      flattering the ones that happen to trust their lookup.
///
///      Price schema. The survey's §3 shape was
///        (uint256 tokenId, uint8 sourceId, uint128 priceUsdc6, uint24 confidence, bytes32 inputsHash)
///      and it is NOT sufficient under Tim's 18:21Z rule: a valuation has to name the cycle it
///      belongs to or there is nothing to check against its writer's closed cycles. EAS has no
///      cycle concept of its own, so the field has to live in the attestation data. The schema
///      measured here is therefore
///        (uint256 tokenId, uint8 sourceId, uint128 priceUsdc6, uint24 confidence, uint64 cycle,
///         bytes32 inputsHash)
///      which is 192 bytes rather than 160 — one extra word on every single write, on every EAS
///      arm. That is a required addition, not an optimisation, and it belongs on the list of
///      guards the move to EAS has to rebuild.
abstract contract EasArmBase is BenchAggregatorBase {
    /// @notice Deployed EAS core. Ownerless, non-proxy, v0.26.
    IEAS public immutable eas;
    /// @notice The registered price schema uid.
    bytes32 public immutable priceSchema;
    /// @notice The registered cycle-close schema uid: (address writer, uint64 cycle, bytes32 root).
    bytes32 public immutable cycleCloseSchema;
    /// @notice The registered coverage schema uid: (uint256 tokenId, uint64 cycle).
    bytes32 public immutable coverageSchema;
    /// @notice Whether this instance enforces a per-writer heartbeat. See `_heartbeatFresh`.
    bool public immutable requireHeartbeat;

    /// @notice The trusted writer set, fixed at deploy per round-2 position 3.
    address internal immutable _writer0;
    address internal immutable _writer1;
    address internal immutable _writer2;

    /// @notice Cap on the `refUID` walk, so a malicious or broken chain cannot burn the block.
    uint256 public constant MAX_WALK_HOPS = 64;

    /// @notice The EAS wiring an arm needs, grouped so subclasses stay shallow.
    struct EasConfig {
        address eas;
        bytes32 priceSchema;
        bytes32 cycleCloseSchema;
        bytes32 coverageSchema;
        bool requireHeartbeat;
        address[3] writers;
    }

    constructor(AggConfig memory cfg, EasConfig memory easCfg) BenchAggregatorBase(cfg) {
        if (easCfg.eas == address(0) || easCfg.priceSchema == bytes32(0)) revert InvalidConfig();
        eas = IEAS(easCfg.eas);
        priceSchema = easCfg.priceSchema;
        cycleCloseSchema = easCfg.cycleCloseSchema;
        coverageSchema = easCfg.coverageSchema;
        requireHeartbeat = easCfg.requireHeartbeat;
        _writer0 = easCfg.writers[0];
        _writer1 = easCfg.writers[1];
        _writer2 = easCfg.writers[2];
    }

    /// @notice The oracle writer address publishing for an oracle source.
    function writerOf(uint8 sourceId) public view returns (address) {
        if (sourceId == 0) return _writer0;
        if (sourceId == 1) return _writer1;
        return _writer2;
    }

    /// @notice How this arm finds the head attestation for a row. The arms' only difference.
    function _headUid(uint8 sourceId, uint256 tokenId, Ctx memory ctx) internal view virtual returns (bytes32);

    /// @notice How this arm finds the writer's coverage stamp for one token, when the stamp is
    ///         an attestation rather than a contract slot.
    function _coverageUid(uint8 sourceId, uint256 tokenId, Ctx memory ctx) internal view virtual returns (bytes32);

    /// @notice How this arm finds the writer's latest cycle-close attestation.
    function _cycleCloseUid(uint8 sourceId, Ctx memory ctx) internal view virtual returns (bytes32);

    // -------------------------------------------------------------------------
    // Fact-layer hooks
    // -------------------------------------------------------------------------

    function _current(uint8 sourceId, uint256 tokenId, Ctx memory ctx)
        internal
        view
        override
        returns (PriceFact memory fact)
    {
        bytes32 uid = _headUid(sourceId, tokenId, ctx);
        if (uid == bytes32(0)) return fact;
        (bool ok, PriceFact memory f,) = _readPrice(uid, sourceId, tokenId, true);
        return ok ? f : fact;
    }

    function _previous(uint8 sourceId, uint256 tokenId, Ctx memory ctx)
        internal
        view
        override
        returns (PriceFact memory fact)
    {
        bytes32 uid = _headUid(sourceId, tokenId, ctx);
        if (uid == bytes32(0)) return fact;
        (bool ok,, bytes32 refUID) = _readPrice(uid, sourceId, tokenId, true);
        if (!ok || refUID == bytes32(0)) return fact;
        // A superseded attestation is revoked by the writer in the same transaction as its
        // replacement, so history hops must be read WITHOUT the revocation check. Revocation
        // means "not the live head", not "never happened".
        (bool ok2, PriceFact memory prev,) = _readPrice(refUID, sourceId, tokenId, false);
        return ok2 ? prev : fact;
    }

    /// @notice Walk the `refUID` chain until a publication old enough to clear seasoning.
    function _asOf(uint8 sourceId, uint256 tokenId, uint64 targetTs, Ctx memory ctx)
        internal
        view
        override
        returns (bool found, uint128 priceUsdc6, uint256 hops)
    {
        bytes32 uid = _headUid(sourceId, tokenId, ctx);
        bool head = true;
        while (uid != bytes32(0) && hops < MAX_WALK_HOPS) {
            (bool ok, PriceFact memory f, bytes32 refUID) = _readPrice(uid, sourceId, tokenId, head);
            if (!ok) return (false, 0, hops);
            if (f.lastWrittenAt != 0 && f.lastWrittenAt <= targetTs && f.priceUsdc6 != 0) {
                return (true, f.priceUsdc6, hops);
            }
            uid = refUID;
            head = false;
            unchecked {
                ++hops;
            }
        }
        return (false, 0, hops);
    }

    /// @notice Per-writer liveness.
    /// @dev EAS has no heartbeat primitive — the survey's "no dead-man-switch on the attester".
    ///      Rebuilding it costs one extra lookup plus one `getAttestation` per oracle source per
    ///      read, which is why it is switchable: the experiment measures `price()` with it and
    ///      without it, so the cost of the missing primitive is a number rather than a caveat.
    /// @dev One `getAttestation` answers both questions: the cycle-close attestation carries the
    ///      time (liveness) and the cycle number (what has been closed). Cycles are monotonic, so
    ///      the latest close covers every cycle at or below it. Schema
    ///      `(address writer, uint64 cycle, bytes32 root)`; the root is the audit commitment and
    ///      nothing on chain verifies a path against it.
    function _writerLiveness(uint8 sourceId, Ctx memory ctx)
        internal
        view
        override
        returns (bool fresh, uint64 closedCycle, bytes32 root)
    {
        bytes32 uid = _cycleCloseUid(sourceId, ctx);
        if (uid == bytes32(0)) return (!requireHeartbeat && coverage == CoverageMode.None, 0, bytes32(0));
        Attestation memory att = eas.getAttestation(uid);
        if (att.uid == bytes32(0)) return (false, 0, bytes32(0));
        if (att.schema != cycleCloseSchema) return (false, 0, bytes32(0));
        if (att.attester != writerOf(sourceId)) return (false, 0, bytes32(0));
        if (att.revocationTime != 0) return (false, 0, bytes32(0));
        if (att.data.length != 96) return (false, 0, bytes32(0));
        (, uint64 attCycle, bytes32 attRoot) = abi.decode(att.data, (address, uint64, bytes32));
        fresh = !requireHeartbeat || uint256(att.time) + uint256(maxSilence) >= block.timestamp;
        return (fresh, attCycle, attRoot);
    }

    /// @notice Coverage stamp read for an arm that owns no contract: the stamp is an attestation
    ///         under the coverage schema `(uint256 tokenId, uint64 cycle)`, so reading it costs a
    ///         uid lookup plus a full `getAttestation`, not one SLOAD. That asymmetry against the
    ///         pointer arm is a real property of owning no contract, and it is measured.
    function _coveredThrough(uint8 sourceId, uint256 tokenId, Ctx memory ctx)
        internal
        view
        virtual
        override
        returns (uint64)
    {
        bytes32 uid = _coverageUid(sourceId, tokenId, ctx);
        if (uid == bytes32(0)) return 0;
        Attestation memory att = eas.getAttestation(uid);
        if (att.uid == bytes32(0)) return 0;
        if (att.schema != coverageSchema) return 0;
        if (att.attester != writerOf(sourceId)) return 0;
        if (att.revocationTime != 0) return 0;
        if (att.data.length != 64) return 0;
        (uint256 attTokenId, uint64 attCycle) = abi.decode(att.data, (uint256, uint64));
        if (attTokenId != tokenId) return 0;
        return attCycle;
    }

    /// @notice The writer lock. On EAS the lock IS revocation of the head price attestation:
    ///         attester-only, enforced inside `_revoke`, with no central authority anywhere.
    /// @dev Checked inside `_readPrice`, so a revoked head simply stops being live. Reporting it
    ///      here as a separate lock read would double the lookup for no behavioural difference.
    function _isLocked(uint8, uint256, Ctx memory) internal pure override returns (bool) {
        return false;
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /// @notice Read and hard-validate one price attestation.
    /// @param enforceLive When true this is the live head: revocation and expiry disqualify it.
    ///        When false this is a history hop, where revocation is expected.
    function _readPrice(bytes32 uid, uint8 sourceId, uint256 tokenId, bool enforceLive)
        internal
        view
        returns (bool ok, PriceFact memory fact, bytes32 refUID)
    {
        Attestation memory att = eas.getAttestation(uid);
        if (att.uid == bytes32(0)) return (false, fact, bytes32(0));
        if (att.schema != priceSchema) return (false, fact, bytes32(0));
        if (att.attester != writerOf(sourceId)) return (false, fact, bytes32(0));
        if (enforceLive) {
            if (att.revocationTime != 0) return (false, fact, bytes32(0));
            if (att.expirationTime != 0 && uint256(att.expirationTime) <= block.timestamp) {
                return (false, fact, bytes32(0));
            }
        }
        if (att.data.length != 192) return (false, fact, bytes32(0));
        (uint256 attTokenId, uint8 attSourceId, uint128 priceUsdc6,, uint64 attCycle,) =
            abi.decode(att.data, (uint256, uint8, uint128, uint24, uint64, bytes32));
        if (attTokenId != tokenId || attSourceId != sourceId) return (false, fact, bytes32(0));
        fact = PriceFact({present: true, priceUsdc6: priceUsdc6, lastWrittenAt: att.time, cycle: attCycle});
        return (true, fact, att.refUID);
    }
}
