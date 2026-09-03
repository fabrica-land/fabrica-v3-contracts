// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ENG-3922 arm 3 — the ownerless fact store (adoption survey Option B).
/// @dev `FabricaAttributeOracle` stripped of every privileged role, per round-2 position 2 and
///      Part A item 4: no owner, no oracle-writer allowlist, no per-token `register` gate, no
///      owner knobs, no `validatorId` (it existed only to namespace an allowlist). A writer's
///      row is addressed by `msg.sender`, so no writer can touch another's.
///
///      What survives from the 741-line round-1 store: value, writer, timestamp, cycle, the
///      history ring the aggregator's seasoning walk needs, a per-writer heartbeat, and a
///      per-writer lock. Cycle invalidation stays because the glossary makes a cycle a
///      per-writer notion; `setMinValidCycle` here moves the caller's own floor only, which is
///      a writer power, not an owner power.
///
///      Deliberately absent, and therefore on the ticket-bullet-5 list of write-time guards
///      that must be rebuilt in the aggregator or consciously dropped: the price band
///      (`maxUpBps` / `maxDownBps`), `minWriteInterval`, the first-price cap
///      (`maxFirstPriceUsdc6`), and the global value ceiling.
contract OwnerlessFactStore {
    struct Fact {
        uint128 priceUsdc6;
        uint24 confidenceScore;
        uint64 valuedAt;
        uint64 lastWrittenAt;
        uint64 cycle;
        bytes32 inputsHash;
    }

    struct HistoryEntry {
        uint128 priceUsdc6;
        uint64 lastWrittenAt;
        uint64 cycle;
    }

    /// @notice History ring depth, matching the round-1 store's 48 so the arms compare like for like.
    uint8 public immutable historyDepth;

    /// @notice writer => tokenId => current price fact.
    mapping(address => mapping(uint256 => Fact)) private _facts;
    /// @notice writer => tokenId => ring slot => history entry.
    mapping(address => mapping(uint256 => mapping(uint256 => HistoryEntry))) private _history;
    /// @notice writer => tokenId => total history writes (head slot = (count - 1) % depth).
    mapping(address => mapping(uint256 => uint256)) private _historyCount;
    /// @notice writer => tokenId => the writer's own lock on its own facts.
    mapping(address => mapping(uint256 => bool)) public locked;
    /// @notice writer => last heartbeat timestamp.
    mapping(address => uint64) public lastHeartbeatAt;
    /// @notice writer => last heartbeat cycle.
    mapping(address => uint64) public lastHeartbeatCycle;
    /// @notice writer => the writer's own minimum valid cycle; facts below it are dead.
    mapping(address => uint64) public minValidCycle;

    event PriceWritten(address indexed writer, uint256 indexed tokenId, uint128 priceUsdc6, uint64 cycle);
    event Heartbeat(address indexed writer, uint64 cycle, uint64 timestamp);
    event LockSet(address indexed writer, uint256 indexed tokenId, bool locked);
    event MinValidCycleSet(address indexed writer, uint64 minValidCycle);

    error InvalidPrice();
    error CycleTooLow(uint64 floor, uint64 given);
    error CycleNotMonotonic(uint64 stored, uint64 given);
    error InvalidValuedAt(uint64 valuedAt, uint64 nowTs);
    error LengthMismatch();
    error HistoryIndexOutOfBounds(uint256 index, uint256 length);
    error HistoryDepthZero();

    constructor(uint8 historyDepth_) {
        if (historyDepth_ == 0) revert HistoryDepthZero();
        historyDepth = historyDepth_;
    }

    // -------------------------------------------------------------------------
    // Writes — every one of them under `msg.sender`'s own row
    // -------------------------------------------------------------------------

    /// @notice Publish one price under the caller's own row, and refresh the caller's heartbeat.
    function writePrice(uint256 tokenId, uint128 priceUsdc6, uint24 confidenceScore, uint64 valuedAt, uint64 cycle)
        external
    {
        _writePrice(tokenId, priceUsdc6, confidenceScore, valuedAt, cycle);
        _touchHeartbeat(cycle);
    }

    /// @notice Prototype batched write: N tokens in one transaction, one heartbeat at the end.
    /// @dev Round-3 candidate (round-2 proposal Part A item 12); measured here, not shipped.
    function writePriceBatch(
        uint256[] calldata tokenIds,
        uint128[] calldata pricesUsdc6,
        uint24[] calldata confidenceScores,
        uint64[] calldata valuedAts,
        uint64 cycle
    ) external {
        uint256 n = tokenIds.length;
        if (n != pricesUsdc6.length || n != confidenceScores.length || n != valuedAts.length) {
            revert LengthMismatch();
        }
        for (uint256 i; i < n; ++i) {
            _writePrice(tokenIds[i], pricesUsdc6[i], confidenceScores[i], valuedAts[i], cycle);
        }
        _touchHeartbeat(cycle);
    }

    /// @notice Standalone heartbeat for a cycle in which the caller published nothing.
    function heartbeat(uint64 cycle) external {
        if (cycle < minValidCycle[msg.sender]) revert CycleTooLow(minValidCycle[msg.sender], cycle);
        _touchHeartbeat(cycle);
    }

    /// @notice Lock or unlock the caller's own facts about a token; no central authority exists.
    function setLock(uint256 tokenId, bool value) external {
        locked[msg.sender][tokenId] = value;
        emit LockSet(msg.sender, tokenId, value);
    }

    /// @notice Raise the caller's own minimum valid cycle, killing every older fact of its own.
    function setMinValidCycle(uint64 newMinValidCycle) external {
        if (newMinValidCycle < minValidCycle[msg.sender]) {
            revert CycleTooLow(minValidCycle[msg.sender], newMinValidCycle);
        }
        minValidCycle[msg.sender] = newMinValidCycle;
        emit MinValidCycleSet(msg.sender, newMinValidCycle);
    }

    // -------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------

    function getFact(address writer, uint256 tokenId) external view returns (Fact memory) {
        return _facts[writer][tokenId];
    }

    function isCycleValid(address writer, uint64 cycle) external view returns (bool) {
        return cycle >= minValidCycle[writer];
    }

    function historyLength(address writer, uint256 tokenId) external view returns (uint256) {
        uint256 count = _historyCount[writer][tokenId];
        uint256 depth = historyDepth;
        return count < depth ? count : depth;
    }

    /// @notice History newest-first; index 0 is the most recent superseded value.
    function getHistory(address writer, uint256 tokenId, uint256 index) external view returns (HistoryEntry memory) {
        uint256 count = _historyCount[writer][tokenId];
        uint256 depth = historyDepth;
        uint256 len = count < depth ? count : depth;
        if (index >= len) revert HistoryIndexOutOfBounds(index, len);
        return _history[writer][tokenId][(count - 1 - index) % depth];
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _writePrice(uint256 tokenId, uint128 priceUsdc6, uint24 confidenceScore, uint64 valuedAt, uint64 cycle)
        internal
    {
        if (priceUsdc6 == 0) revert InvalidPrice();
        if (cycle < minValidCycle[msg.sender]) revert CycleTooLow(minValidCycle[msg.sender], cycle);
        uint64 nowTs = uint64(block.timestamp);
        uint64 effectiveValuedAt = valuedAt == 0 ? nowTs : valuedAt;
        if (effectiveValuedAt > nowTs) revert InvalidValuedAt(effectiveValuedAt, nowTs);
        Fact storage current = _facts[msg.sender][tokenId];
        if (current.priceUsdc6 != 0) {
            if (cycle < current.cycle) revert CycleNotMonotonic(current.cycle, cycle);
            uint256 count = _historyCount[msg.sender][tokenId];
            _history[msg.sender][tokenId][count % historyDepth] = HistoryEntry({
                priceUsdc6: current.priceUsdc6, lastWrittenAt: current.lastWrittenAt, cycle: current.cycle
            });
            _historyCount[msg.sender][tokenId] = count + 1;
        }
        current.priceUsdc6 = priceUsdc6;
        current.confidenceScore = confidenceScore;
        current.valuedAt = effectiveValuedAt;
        current.lastWrittenAt = nowTs;
        current.cycle = cycle;
        emit PriceWritten(msg.sender, tokenId, priceUsdc6, cycle);
    }

    function _touchHeartbeat(uint64 cycle) internal {
        uint64 nowTs = uint64(block.timestamp);
        lastHeartbeatAt[msg.sender] = nowTs;
        if (cycle > lastHeartbeatCycle[msg.sender]) lastHeartbeatCycle[msg.sender] = cycle;
        emit Heartbeat(msg.sender, cycle, nowTs);
    }
}
