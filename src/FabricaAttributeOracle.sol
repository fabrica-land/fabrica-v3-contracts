// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @notice On-chain multi-feed fact store for property values, attributes, and provenance.
/// @dev NOT an IPriceOracle. The launch pool's IPriceOracle entrypoint is the renounced
///      aggregator (ENG-3519). Storage/read model is the 2026-07-29 Phase-0 lock on ENG-3518.
///      Fabrica relays facts; the renounced aggregator holds the rules.
contract FabricaAttributeOracle is Ownable2Step, EIP712 {
    using ECDSA for bytes32;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice Recovery status digit: Normal (borrowable). Aligns with scoring digit 7.
    uint8 public constant RECOVERY_NORMAL = 7;
    /// @notice Recovery status digit: Recovery pending.
    uint8 public constant RECOVERY_PENDING = 6;
    /// @notice Recovery status digit: Stolen.
    uint8 public constant RECOVERY_STOLEN = 5;
    /// @notice Recovery status digit: Distressed (reversible).
    uint8 public constant RECOVERY_DISTRESSED = 4;
    /// @notice Recovery status digit: Void (irreversible).
    uint8 public constant RECOVERY_VOID = 1;

    /// @notice Basis-point denominator for write-time band knobs.
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice EIP-712 typehash for relayed price writes (includes full Provenance + deadline).
    bytes32 public constant PRICE_WRITE_TYPEHASH = keccak256(
        "PriceWrite(uint256 validatorId,uint256 tokenId,uint8 sourceId,uint128 priceUsdc6,"
        "uint24 confidenceScore,uint64 valuedAt,uint64 cycle,bytes32 rawPayloadHash,"
        "bytes32 inputsHash,uint64 provenanceTimestamp,address signer,uint256 nonce,uint256 deadline)"
    );

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Provenance record for an attested fact (TEE-ready: no format change later).
    struct Provenance {
        bytes32 rawPayloadHash;
        bytes32 inputsHash;
        uint64 timestamp;
        address signer;
    }

    /// @notice Current per-source value record.
    struct SourcePrice {
        uint128 priceUsdc6;
        uint24 confidenceScore;
        uint64 valuedAt;
        /// @notice Wall-clock of last successful write (rate-limit key; not publisher-controlled).
        uint64 lastWrittenAt;
        uint64 cycle;
        Provenance provenance;
    }

    /// @notice Compact history ring entry for temporal defenses in the aggregator.
    struct HistoryEntry {
        uint128 priceUsdc6;
        uint64 valuedAt;
        uint64 cycle;
    }

    /// @notice Dense-index registry entry for a token under a validator.
    struct RegistryEntry {
        uint64 registeredAt;
        uint32 index;
        bool registered;
    }

    /// @notice Attribute fact (parcel-intrinsic; never an opaque eligibility score).
    struct AttributeFact {
        bytes32 value;
        uint64 cycle;
        Provenance provenance;
    }

    /// @notice Constructor / deploy defaults for parameterized knobs.
    struct KnobConfig {
        uint16 maxUpBps;
        uint16 maxDownBps;
        uint128 maxFirstPriceUsdc6;
        uint64 maxSilence;
        uint64 minWriteInterval;
        uint64 registrySeasonDelay;
        uint128 valueCeilingUsdc6;
        uint8 historyDepth;
    }

    /// @notice Packed price-write arguments (keeps calldata surface shallow for stack depth).
    struct PriceWriteParams {
        uint256 validatorId;
        uint256 tokenId;
        uint8 sourceId;
        uint128 priceUsdc6;
        uint24 confidenceScore;
        uint64 valuedAt;
        uint64 cycle;
        Provenance provenance;
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidPrice();
    error InvalidCycle();
    error InvalidRecoveryStatus(uint8 status);
    error VoidIsIrreversible();
    error NotRegistered(uint256 validatorId, uint256 tokenId);
    error AlreadyRegistered(uint256 validatorId, uint256 tokenId);
    error NotPricePublisher(uint256 validatorId, address caller);
    error NotRecoveryWriter(uint256 validatorId, address caller);
    error BandExceeded(uint128 lastPrice, uint128 newPrice, uint16 maxUpBps, uint16 maxDownBps);
    error FirstPriceTooHigh(uint128 price, uint128 maxFirstPrice);
    error AboveValueCeiling(uint128 price, uint128 ceiling);
    error WriteTooSoon(uint64 lastWriteAt, uint64 minInterval, uint64 nowTs);
    error InvalidKnob();
    error SourceNotEnabled(uint8 sourceId);
    error InvalidSignature();
    error InvalidNonce(uint256 expected, uint256 actual);
    error HistoryDepthZero();
    error HistoryIndexOutOfBounds(uint256 index, uint256 length);
    error InvalidValuedAt(uint64 valuedAt, uint64 nowTs);
    error ProvenanceSignerMismatch(address expected, address actual);
    error ExpiredSignature(uint256 deadline, uint256 nowTs);
    error OwnershipRenounceDisabled();
    error CycleNotMonotonic(uint64 currentCycle, uint64 newCycle);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PriceWritten(
        uint256 indexed validatorId,
        uint256 indexed tokenId,
        uint8 indexed sourceId,
        uint128 priceUsdc6,
        uint24 confidenceScore,
        uint64 valuedAt,
        uint64 cycle,
        bytes32 provenanceHash
    );
    event AttributeWritten(
        uint256 indexed validatorId,
        uint256 indexed tokenId,
        bytes32 indexed attributeId,
        bytes32 value,
        uint64 cycle,
        bytes32 provenanceHash
    );
    event IndexAssigned(uint256 indexed validatorId, uint256 indexed tokenId, uint32 index, uint64 registeredAt);
    event KeeperHeartbeat(uint256 indexed validatorId, uint64 cycle, uint64 timestamp);
    event RecoveryStatusSet(uint256 indexed validatorId, uint256 indexed tokenId, uint8 status, address indexed writer);
    event CycleInvalidated(uint256 indexed validatorId, uint64 minValidCycle);
    event RootAnchored(uint256 indexed validatorId, uint64 cycle, bytes32 root);
    event PricePublisherSet(uint256 indexed validatorId, address indexed publisher, bool allowed);
    event RecoveryWriterSet(uint256 indexed validatorId, address indexed writer, bool allowed);
    event SourceEnabledSet(uint8 indexed sourceId, bool enabled);
    event KnobsUpdated(
        uint16 maxUpBps,
        uint16 maxDownBps,
        uint128 maxFirstPriceUsdc6,
        uint64 maxSilence,
        uint64 minWriteInterval,
        uint64 registrySeasonDelay,
        uint128 valueCeilingUsdc6
    );

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Write-time max upward move in bps vs last stored price (deploy default 1500 = 15%).
    uint16 public maxUpBps;
    /// @notice Write-time max downward move in bps vs last stored price (deploy default 5000 = 50%).
    uint16 public maxDownBps;
    /// @notice Hard cap on first nonzero write per source (first-price has no temporal floor).
    uint128 public maxFirstPriceUsdc6;
    /// @notice Dead-man: max silence after last heartbeat before underwriting should fail closed.
    uint64 public maxSilence;
    /// @notice Min seconds between writes to the same (validator, token, source).
    uint64 public minWriteInterval;
    /// @notice Token registry seasoning delay (seconds after register before seasoned).
    uint64 public registrySeasonDelay;
    /// @notice Absolute ceiling for any stored price (USDC 1e6).
    uint128 public valueCeilingUsdc6;
    /// @notice History ring depth per (validator, token, source). Immutable after deploy.
    uint8 public immutable historyDepth;

    /// @notice Next dense index per validator (1-based assignment).
    mapping(uint256 => uint32) public nextIndex;
    /// @notice Registry keyed by validator and tokenId.
    mapping(uint256 => mapping(uint256 => RegistryEntry)) public registry;
    /// @notice Current source prices.
    mapping(uint256 => mapping(uint256 => mapping(uint8 => SourcePrice))) private _sourcePrices;
    /// @notice History ring slots: [validator][tokenId][sourceId][slot % historyDepth].
    mapping(uint256 => mapping(uint256 => mapping(uint8 => mapping(uint256 => HistoryEntry)))) private _history;
    /// @notice Total history writes (head = count; slot = (count - 1) % depth).
    mapping(uint256 => mapping(uint256 => mapping(uint8 => uint256))) private _historyCount;
    /// @notice recoveryStatus digit per token (0 = unset / not borrowable; register seeds Normal).
    mapping(uint256 => mapping(uint256 => uint8)) private _recoveryStatus;
    /// @notice Attribute facts.
    mapping(uint256 => mapping(uint256 => mapping(bytes32 => AttributeFact))) private _attributes;
    /// @notice Authorized price publishers per validator.
    mapping(uint256 => mapping(address => bool)) public pricePublishers;
    /// @notice Authorized recovery writers per validator (≠ publisher by design).
    mapping(uint256 => mapping(address => bool)) public recoveryWriters;
    /// @notice Enabled source ids (0=Prycd, 1=OpenAVM, 2=Regrid tax by convention).
    mapping(uint8 => bool) public sourceEnabled;
    /// @notice Last heartbeat timestamp per validator.
    mapping(uint256 => uint64) public lastHeartbeatAt;
    /// @notice Last heartbeat cycle per validator.
    mapping(uint256 => uint64) public lastHeartbeatCycle;
    /// @notice Global min valid cycle kill switch per validator.
    mapping(uint256 => uint64) public minValidCycle;
    /// @notice Last anchored Merkle root per validator/cycle.
    mapping(uint256 => mapping(uint64 => bytes32)) public cycleRoot;
    /// @notice EIP-712 relay nonces per publisher.
    mapping(address => uint256) public nonces;

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    /// @notice Deploy the fact store with owner and parameterized knobs.
    /// @param owner_ Safe / multisig owner (Ownable2Step).
    /// @param knobs_ Deploy defaults for write-time and liveness knobs.
    constructor(address owner_, KnobConfig memory knobs_) Ownable(owner_) EIP712("FabricaAttributeOracle", "1") {
        // Ownable reverts OwnableInvalidOwner on address(0).
        if (knobs_.historyDepth == 0) revert HistoryDepthZero();
        _validateKnobs(
            knobs_.maxUpBps,
            knobs_.maxDownBps,
            knobs_.maxFirstPriceUsdc6,
            knobs_.maxSilence,
            knobs_.minWriteInterval,
            knobs_.registrySeasonDelay,
            knobs_.valueCeilingUsdc6
        );
        historyDepth = knobs_.historyDepth;
        maxUpBps = knobs_.maxUpBps;
        maxDownBps = knobs_.maxDownBps;
        maxFirstPriceUsdc6 = knobs_.maxFirstPriceUsdc6;
        maxSilence = knobs_.maxSilence;
        minWriteInterval = knobs_.minWriteInterval;
        registrySeasonDelay = knobs_.registrySeasonDelay;
        valueCeilingUsdc6 = knobs_.valueCeilingUsdc6;
        // v1 source set: Prycd, OpenAVM, Regrid tax-assessor.
        sourceEnabled[0] = true;
        sourceEnabled[1] = true;
        sourceEnabled[2] = true;
    }

    /// @notice Start-proposal deploy defaults from the Phase-0 lock (band +15/−50, silence 24h, …).
    function defaultKnobs() external pure returns (KnobConfig memory) {
        return KnobConfig({
            maxUpBps: 1500,
            maxDownBps: 5000,
            // $50M USDC (6 decimals) — conservative first-price ceiling pending Tim/Fede review.
            maxFirstPriceUsdc6: 50_000_000e6,
            maxSilence: 24 hours,
            minWriteInterval: 1 hours,
            registrySeasonDelay: 1 days,
            // Same as first-price default until class ceilings are set.
            valueCeilingUsdc6: 50_000_000e6,
            historyDepth: 48
        });
    }

    // -------------------------------------------------------------------------
    // Admin — roles and knobs
    // -------------------------------------------------------------------------

    /// @notice Authorize or revoke a price publisher for a validator.
    function setPricePublisher(uint256 validatorId, address publisher, bool allowed) external onlyOwner {
        if (publisher == address(0)) revert ZeroAddress();
        pricePublishers[validatorId][publisher] = allowed;
        emit PricePublisherSet(validatorId, publisher, allowed);
    }

    /// @notice Authorize or revoke a recovery-status writer for a validator.
    function setRecoveryWriter(uint256 validatorId, address writer, bool allowed) external onlyOwner {
        if (writer == address(0)) revert ZeroAddress();
        recoveryWriters[validatorId][writer] = allowed;
        emit RecoveryWriterSet(validatorId, writer, allowed);
    }

    /// @notice Enable or disable a source id for writes.
    function setSourceEnabled(uint8 sourceId, bool enabled) external onlyOwner {
        sourceEnabled[sourceId] = enabled;
        emit SourceEnabledSet(sourceId, enabled);
    }

    /// @notice Update write-time and liveness knobs. Tighten or loosen; real deploys review values.
    function setKnobs(
        uint16 maxUpBps_,
        uint16 maxDownBps_,
        uint128 maxFirstPriceUsdc6_,
        uint64 maxSilence_,
        uint64 minWriteInterval_,
        uint64 registrySeasonDelay_,
        uint128 valueCeilingUsdc6_
    ) external onlyOwner {
        _validateKnobs(
            maxUpBps_,
            maxDownBps_,
            maxFirstPriceUsdc6_,
            maxSilence_,
            minWriteInterval_,
            registrySeasonDelay_,
            valueCeilingUsdc6_
        );
        maxUpBps = maxUpBps_;
        maxDownBps = maxDownBps_;
        maxFirstPriceUsdc6 = maxFirstPriceUsdc6_;
        maxSilence = maxSilence_;
        minWriteInterval = minWriteInterval_;
        registrySeasonDelay = registrySeasonDelay_;
        valueCeilingUsdc6 = valueCeilingUsdc6_;
        emit KnobsUpdated(
            maxUpBps_,
            maxDownBps_,
            maxFirstPriceUsdc6_,
            maxSilence_,
            minWriteInterval_,
            registrySeasonDelay_,
            valueCeilingUsdc6_
        );
    }

    /// @notice Bump minValidCycle — kill switch that invalidates all records with cycle below it.
    function setMinValidCycle(uint256 validatorId, uint64 newMinValidCycle) external onlyOwner {
        if (newMinValidCycle <= minValidCycle[validatorId]) revert InvalidCycle();
        minValidCycle[validatorId] = newMinValidCycle;
        emit CycleInvalidated(validatorId, newMinValidCycle);
    }

    /// @notice Anchor a whole-book Merkle root for a cycle (not on the borrow path).
    function anchorRoot(uint256 validatorId, uint64 cycle, bytes32 root) external onlyOwner {
        cycleRoot[validatorId][cycle] = root;
        emit RootAnchored(validatorId, cycle, root);
    }

    /// @notice Owner-only dense-index registration (multisig). Starts registry seasoning clock.
    function register(uint256 validatorId, uint256 tokenId) external onlyOwner {
        _register(validatorId, tokenId);
    }

    /// @notice Batch register for backfill (owner-only).
    function registerBatch(uint256 validatorId, uint256[] calldata tokenIds) external onlyOwner {
        uint256 len = tokenIds.length;
        for (uint256 i; i < len; ++i) {
            _register(validatorId, tokenIds[i]);
        }
    }

    // -------------------------------------------------------------------------
    // Writes — price publisher
    // -------------------------------------------------------------------------

    /// @notice Direct price write (default publisher path). Provenance.signer must equal msg.sender.
    function writePrice(PriceWriteParams calldata params) external {
        _requirePricePublisher(params.validatorId, msg.sender);
        if (params.provenance.signer != msg.sender) {
            revert ProvenanceSignerMismatch(msg.sender, params.provenance.signer);
        }
        _writePrice(params);
    }

    /// @notice EIP-712 relayed price write (publisher signs; any relayer may submit).
    /// @param deadline Unix timestamp after which the signature is rejected.
    function writePriceRelayed(
        PriceWriteParams calldata params,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert ExpiredSignature(deadline, block.timestamp);
        address publisher = params.provenance.signer;
        _requirePricePublisher(params.validatorId, publisher);
        uint256 expected = nonces[publisher];
        if (nonce != expected) revert InvalidNonce(expected, nonce);
        address recovered = _hashTypedDataV4(_priceWriteStructHash(params, nonce, deadline)).recover(signature);
        if (recovered != publisher) revert InvalidSignature();
        nonces[publisher] = expected + 1;
        _writePrice(params);
    }

    /// @notice Write a parcel-intrinsic attribute fact with provenance.
    function writeAttribute(
        uint256 validatorId,
        uint256 tokenId,
        bytes32 attributeId,
        bytes32 value,
        uint64 cycle,
        Provenance calldata provenance
    ) external {
        _requirePricePublisher(validatorId, msg.sender);
        _requireRegistered(validatorId, tokenId);
        _requireValidCycle(validatorId, cycle);
        if (provenance.signer != msg.sender) {
            revert ProvenanceSignerMismatch(msg.sender, provenance.signer);
        }
        _attributes[validatorId][tokenId][attributeId] =
            AttributeFact({value: value, cycle: cycle, provenance: provenance});
        emit AttributeWritten(validatorId, tokenId, attributeId, value, cycle, _provenanceHash(provenance));
    }

    /// @notice Keeper heartbeat (standalone write on quiet cycles).
    function heartbeat(uint256 validatorId, uint64 cycle) external {
        _requirePricePublisher(validatorId, msg.sender);
        _requireValidCycle(validatorId, cycle);
        _touchHeartbeat(validatorId, cycle);
    }

    // -------------------------------------------------------------------------
    // Writes — recovery writer
    // -------------------------------------------------------------------------

    /// @notice Set recovery status. Void is irreversible. Separate role from price publisher.
    function setRecoveryStatus(uint256 validatorId, uint256 tokenId, uint8 status) external {
        if (!recoveryWriters[validatorId][msg.sender]) {
            revert NotRecoveryWriter(validatorId, msg.sender);
        }
        _requireRegistered(validatorId, tokenId);
        if (!_isValidRecoveryStatus(status)) revert InvalidRecoveryStatus(status);
        uint8 current = _recoveryStatus[validatorId][tokenId];
        if (current == RECOVERY_VOID && status != RECOVERY_VOID) revert VoidIsIrreversible();
        _recoveryStatus[validatorId][tokenId] = status;
        emit RecoveryStatusSet(validatorId, tokenId, status, msg.sender);
    }

    /// @notice Ownership renounce is disabled — this store requires ongoing owner ops.
    function renounceOwnership() public pure override {
        revert OwnershipRenounceDisabled();
    }

    // -------------------------------------------------------------------------
    // Views — fact surface for aggregator / subgraph / tooling
    // -------------------------------------------------------------------------

    /// @notice Current source price record (empty if never written).
    /// @dev Raw storage. Consumers (ENG-3519) MUST call `isCycleValid` on `cycle` after
    ///      `setMinValidCycle` — this view does not tombstone killed cycles (lazy invalidation).
    function getSourcePrice(uint256 validatorId, uint256 tokenId, uint8 sourceId)
        external
        view
        returns (SourcePrice memory)
    {
        return _sourcePrices[validatorId][tokenId][sourceId];
    }

    /// @notice Recovery status digit (0 if never set; register seeds Normal).
    function recoveryStatusOf(uint256 validatorId, uint256 tokenId) external view returns (uint8) {
        return _recoveryStatus[validatorId][tokenId];
    }

    /// @notice True when recovery status is Normal (or unset/0 treated as not Normal for safety).
    /// @dev Unset (0) is not borrowable; register() seeds Normal. Explicit Normal required.
    function isRecoveryNormal(uint256 validatorId, uint256 tokenId) external view returns (bool) {
        return _recoveryStatus[validatorId][tokenId] == RECOVERY_NORMAL;
    }

    /// @notice Attribute fact for a key.
    function getAttribute(uint256 validatorId, uint256 tokenId, bytes32 attributeId)
        external
        view
        returns (AttributeFact memory)
    {
        return _attributes[validatorId][tokenId][attributeId];
    }

    /// @notice Whether the token is past registry seasoning delay.
    function isRegistrySeasoned(uint256 validatorId, uint256 tokenId) external view returns (bool) {
        RegistryEntry storage entry = registry[validatorId][tokenId];
        if (!entry.registered) return false;
        return block.timestamp >= uint256(entry.registeredAt) + uint256(registrySeasonDelay);
    }

    /// @notice Whether the validator heartbeat is within maxSilence.
    function isHeartbeatFresh(uint256 validatorId) external view returns (bool) {
        uint64 last = lastHeartbeatAt[validatorId];
        if (last == 0) return false;
        return block.timestamp <= uint256(last) + uint256(maxSilence);
    }

    /// @notice Whether a stored cycle is still valid against minValidCycle.
    function isCycleValid(uint256 validatorId, uint64 cycle) external view returns (bool) {
        return cycle >= minValidCycle[validatorId];
    }

    /// @notice Number of history entries retained for a source (≤ historyDepth).
    function historyLength(uint256 validatorId, uint256 tokenId, uint8 sourceId) external view returns (uint256) {
        uint256 count = _historyCount[validatorId][tokenId][sourceId];
        uint256 depth = historyDepth;
        return count < depth ? count : depth;
    }

    /// @notice Read history newest-first. index 0 = most recent.
    function getHistory(uint256 validatorId, uint256 tokenId, uint8 sourceId, uint256 index)
        external
        view
        returns (HistoryEntry memory)
    {
        uint256 count = _historyCount[validatorId][tokenId][sourceId];
        uint256 depth = historyDepth;
        uint256 len = count < depth ? count : depth;
        if (index >= len) revert HistoryIndexOutOfBounds(index, len);
        // Newest is at slot (count - 1) % depth; index 0 = newest.
        uint256 slot = (count - 1 - index) % depth;
        return _history[validatorId][tokenId][sourceId][slot];
    }

    /// @notice EIP-712 domain separator for relayed writes.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice EIP-712 digest for a relayed price write (for off-chain signers and tests).
    function hashPriceWrite(PriceWriteParams calldata params, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(_priceWriteStructHash(params, nonce, deadline));
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _register(uint256 validatorId, uint256 tokenId) internal {
        RegistryEntry storage entry = registry[validatorId][tokenId];
        if (entry.registered) revert AlreadyRegistered(validatorId, tokenId);
        uint32 index = nextIndex[validatorId] + 1;
        nextIndex[validatorId] = index;
        uint64 registeredAt = uint64(block.timestamp);
        entry.registered = true;
        entry.index = index;
        entry.registeredAt = registeredAt;
        // Fresh tokens default to Normal recovery until a writer sets otherwise.
        if (_recoveryStatus[validatorId][tokenId] == 0) {
            _recoveryStatus[validatorId][tokenId] = RECOVERY_NORMAL;
            emit RecoveryStatusSet(validatorId, tokenId, RECOVERY_NORMAL, msg.sender);
        }
        emit IndexAssigned(validatorId, tokenId, index, registeredAt);
    }

    function _writePrice(PriceWriteParams calldata params) internal {
        if (!sourceEnabled[params.sourceId]) revert SourceNotEnabled(params.sourceId);
        _requireRegistered(params.validatorId, params.tokenId);
        if (params.priceUsdc6 == 0) revert InvalidPrice();
        _requireValidCycle(params.validatorId, params.cycle);
        uint64 nowTs = uint64(block.timestamp);
        uint64 valuedAt = params.valuedAt == 0 ? nowTs : params.valuedAt;
        if (valuedAt > nowTs) revert InvalidValuedAt(valuedAt, nowTs);
        SourcePrice storage current = _sourcePrices[params.validatorId][params.tokenId][params.sourceId];
        if (current.priceUsdc6 == 0) {
            // First-price cap is the specific drain-edge guard; check before generic ceiling.
            if (params.priceUsdc6 > maxFirstPriceUsdc6) {
                revert FirstPriceTooHigh(params.priceUsdc6, maxFirstPriceUsdc6);
            }
        } else {
            if (params.cycle < current.cycle) {
                revert CycleNotMonotonic(current.cycle, params.cycle);
            }
            if (minWriteInterval > 0 && current.lastWrittenAt > 0) {
                if (block.timestamp < uint256(current.lastWrittenAt) + uint256(minWriteInterval)) {
                    revert WriteTooSoon(current.lastWrittenAt, minWriteInterval, nowTs);
                }
            }
            _enforceBand(current.priceUsdc6, params.priceUsdc6);
        }
        if (params.priceUsdc6 > valueCeilingUsdc6) {
            revert AboveValueCeiling(params.priceUsdc6, valueCeilingUsdc6);
        }
        if (current.priceUsdc6 != 0) {
            _pushHistory(
                params.validatorId,
                params.tokenId,
                params.sourceId,
                HistoryEntry({priceUsdc6: current.priceUsdc6, valuedAt: current.valuedAt, cycle: current.cycle})
            );
        }
        current.priceUsdc6 = params.priceUsdc6;
        current.confidenceScore = params.confidenceScore;
        current.valuedAt = valuedAt;
        current.lastWrittenAt = nowTs;
        current.cycle = params.cycle;
        current.provenance = params.provenance;
        _touchHeartbeat(params.validatorId, params.cycle);
        emit PriceWritten(
            params.validatorId,
            params.tokenId,
            params.sourceId,
            params.priceUsdc6,
            params.confidenceScore,
            valuedAt,
            params.cycle,
            _provenanceHash(params.provenance)
        );
    }

    function _priceWriteStructHash(PriceWriteParams calldata params, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                PRICE_WRITE_TYPEHASH,
                params.validatorId,
                params.tokenId,
                params.sourceId,
                params.priceUsdc6,
                params.confidenceScore,
                params.valuedAt,
                params.cycle,
                params.provenance.rawPayloadHash,
                params.provenance.inputsHash,
                params.provenance.timestamp,
                params.provenance.signer,
                nonce,
                deadline
            )
        );
    }

    function _requirePricePublisher(uint256 validatorId, address account) internal view {
        if (!pricePublishers[validatorId][account]) {
            revert NotPricePublisher(validatorId, account);
        }
    }

    function _requireRegistered(uint256 validatorId, uint256 tokenId) internal view {
        if (!registry[validatorId][tokenId].registered) {
            revert NotRegistered(validatorId, tokenId);
        }
    }

    function _requireValidCycle(uint256 validatorId, uint64 cycle) internal view {
        if (cycle < minValidCycle[validatorId]) revert InvalidCycle();
    }

    function _touchHeartbeat(uint256 validatorId, uint64 cycle) internal {
        uint64 ts = uint64(block.timestamp);
        lastHeartbeatAt[validatorId] = ts;
        lastHeartbeatCycle[validatorId] = cycle;
        emit KeeperHeartbeat(validatorId, cycle, ts);
    }

    function _pushHistory(uint256 validatorId, uint256 tokenId, uint8 sourceId, HistoryEntry memory entry) internal {
        uint256 count = _historyCount[validatorId][tokenId][sourceId];
        uint256 slot = count % uint256(historyDepth);
        _history[validatorId][tokenId][sourceId][slot] = entry;
        _historyCount[validatorId][tokenId][sourceId] = count + 1;
    }

    function _enforceBand(uint128 lastPrice, uint128 newPrice) internal view {
        uint256 last = uint256(lastPrice);
        uint256 maxUp = last + (last * uint256(maxUpBps)) / uint256(BPS_DENOMINATOR);
        uint256 maxDown = last - (last * uint256(maxDownBps)) / uint256(BPS_DENOMINATOR);
        if (uint256(newPrice) > maxUp || uint256(newPrice) < maxDown) {
            revert BandExceeded(lastPrice, newPrice, maxUpBps, maxDownBps);
        }
    }

    function _provenanceHash(Provenance memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(p.rawPayloadHash, p.inputsHash, p.timestamp, p.signer));
    }

    function _isValidRecoveryStatus(uint8 status) internal pure returns (bool) {
        return status == RECOVERY_NORMAL || status == RECOVERY_PENDING || status == RECOVERY_STOLEN
            || status == RECOVERY_DISTRESSED || status == RECOVERY_VOID;
    }

    function _validateKnobs(
        uint16 maxUpBps_,
        uint16 maxDownBps_,
        uint128 maxFirstPriceUsdc6_,
        uint64 maxSilence_,
        uint64, /* minWriteInterval_ — 0 allowed */
        uint64, /* registrySeasonDelay_ — 0 allowed */
        uint128 valueCeilingUsdc6_
    ) internal pure {
        if (maxUpBps_ > BPS_DENOMINATOR || maxDownBps_ > BPS_DENOMINATOR) {
            revert InvalidKnob();
        }
        if (maxFirstPriceUsdc6_ == 0 || valueCeilingUsdc6_ == 0) revert InvalidKnob();
        if (maxFirstPriceUsdc6_ > valueCeilingUsdc6_) revert InvalidKnob();
        if (maxSilence_ == 0) revert InvalidKnob();
    }
}
