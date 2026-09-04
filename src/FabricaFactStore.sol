// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Round-2 permissionless fact store: the on-chain record of what each oracle source says
///         about each token, with no privileged roles of any kind.
/// @dev Replaces `FabricaAttributeOracle` (round 1, ENG-3518) rather than upgrading it; the round-1
///      store stays deployed and untouched. Shape selected by ENG-3922's measurement, which put a
///      purpose-built store at 1.00x against 1.88x / 2.07x / 2.36x for the three EAS arms on read
///      gas inside `price()` and 4.1x to 6.1x on the write side.
///
///      Round-2 proposal Part A item 4, ruled by Tim on 3 September 2026: no owner, no writer
///      allowlist, no recovery writer, no central lock authority, and no gate before a write.
///      A row is addressed by the writer's own address, so no writer can reach another's. Trust
///      decisions live entirely in the aggregator, which fixes its trusted writer set at deploy.
///
///      There is deliberately NOTHING in this contract annotated "Sepolia-test-only". Part A item 1
///      permits an owner and settable knobs on a Sepolia test deploy; this design uses neither, so
///      the test deploy and the shape Tim wants shipped are the same code. `historyDepth` is a
///      constructor argument and immutable; every other parameter belongs to a writer.
///
///      Facts are keyed `writer -> tokenId -> kind`. `kind` unifies round 1's two separate
///      keyspaces (per-source prices, per-token attributes) into one record shape. This contract
///      does NOT interpret `kind`: `KIND_PRICE` is published so consumers agree on the key, not so
///      the store can treat prices specially.
contract FabricaFactStore {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice The `kind` under which oracle sources publish valuations, in USDC 1e6.
    /// @dev A convention for consumers, not a branch in this contract's write path.
    bytes32 public constant KIND_PRICE = keccak256("fabrica.fact.price");

    /// @notice Basis-point denominator for a writer's declared band.
    uint16 public constant BPS_DENOMINATOR = 10_000;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice One writer's current statement about one token under one kind.
    /// @dev Three slots, matching the layout ENG-3922 measured on arm 3: `value | confidence |
    ///      valuedAt`, then `writtenAt | cycle`, then `data`. `writtenAt` is the presence marker —
    ///      it is set on every write and never supplied by the caller — so a zero `value` is a
    ///      legitimate value rather than an absent row.
    struct Fact {
        uint128 value;
        uint24 confidence;
        uint64 valuedAt;
        uint64 writtenAt;
        uint64 cycle;
        bytes32 data;
    }

    /// @notice A superseded fact, kept so a consumer can walk back through a seasoning window.
    /// @dev One slot. `valuedAt` and `data` are deliberately not retained: the deployed
    ///      aggregator's seasoning walk reads only the value, the trusted write time and the cycle
    ///      (`FabricaOracleAggregator.sol:406-418`), and a second slot per entry would be paid on
    ///      every superseding write for a field nothing reads.
    struct HistoryEntry {
        uint128 value;
        uint64 writtenAt;
        uint64 cycle;
    }

    /// @notice A writer's own declaration of the limits it holds itself to.
    /// @dev Round 1 carried these as owner-set global knobs (`maxUpBps`, `maxDownBps`,
    ///      `minWriteInterval`). Round 2 moves the authority to the writer and keeps the round-1
    ///      semantics: a write outside the band is REJECTED, so the bad value never exists. That
    ///      is the leg the EAS branch would have lost — there, a rate limit is unrebuildable and a
    ///      band degrades from refusing a write to declining to read a value already published
    ///      under the writer's signature for every other consumer of the schema.
    ///
    ///      Self-declared limits are not a defence against a hostile writer, which is what the
    ///      aggregator's trusted-writer set is for. They are a guardrail an honest writer puts on
    ///      its own pipeline, and every change to one is on chain and emits `PolicyDeclared`, so a
    ///      consumer can see a writer widening its own band.
    struct WriterPolicy {
        uint16 maxUpBps;
        uint16 maxDownBps;
        uint64 minWriteInterval;
        bool bandDeclared;
    }

    /// @notice A writer's statement that it has finished a cycle.
    /// @dev The cycle number only. Tim, 3 September 2026 18:47Z: the Merkle root over the cycle's
    ///      covered tokens is out of round 2 and is a round-3 candidate, and round 2 has no
    ///      on-chain coverage check at all. `closedAt` exists because a consumer needs it to apply
    ///      its own maximum silence; the threshold itself is the aggregator's, not this store's.
    struct CycleClose {
        uint64 cycle;
        uint64 closedAt;
    }

    /// @notice Arguments for one fact write, packed to keep the calldata surface shallow.
    struct FactInput {
        uint256 tokenId;
        bytes32 kind;
        uint128 value;
        uint24 confidence;
        uint64 valuedAt;
        uint64 cycle;
        bytes32 data;
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The caller tried to act on a row that is not its own.
    /// @dev Every mutating function names the writer whose row it touches and proves the caller
    ///      owns it. Keying implicitly off `msg.sender` would make the same guarantee, but a third
    ///      party's attempt on another writer's row would then silently succeed against its OWN
    ///      row instead of reverting, and ENG-3924 requires the isolation be shown by a reverting
    ///      call rather than by reading source.
    error NotWriter(address writer, address caller);
    error InvalidValuedAt(uint64 valuedAt, uint64 nowTs);
    error CycleBelowFloor(uint64 floor, uint64 given);
    error CycleNotMonotonic(uint64 stored, uint64 given);
    error WriteTooSoon(uint64 lastWrittenAt, uint64 minWriteInterval, uint64 nowTs);
    error BandExceeded(uint128 lastValue, uint128 newValue, uint16 maxUpBps, uint16 maxDownBps);
    error InvalidBand(uint16 maxDownBps);
    error HistoryDepthZero();
    error HistoryIndexOutOfBounds(uint256 index, uint256 length);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event FactWritten(
        address indexed writer,
        uint256 indexed tokenId,
        bytes32 indexed kind,
        uint128 value,
        uint24 confidence,
        uint64 valuedAt,
        uint64 cycle,
        bytes32 data
    );
    event CycleClosed(address indexed writer, uint64 cycle, uint64 closedAt);
    event LockSet(address indexed writer, uint256 indexed tokenId, bool locked);
    event MinValidCycleSet(address indexed writer, uint64 minValidCycle);
    event PolicyDeclared(
        address indexed writer, uint16 maxUpBps, uint16 maxDownBps, uint64 minWriteInterval, bool bandDeclared
    );

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice History ring depth per row. Immutable; a constructor argument, not a knob.
    uint8 public immutable historyDepth;

    /// @notice writer => tokenId => kind => the writer's current fact.
    mapping(address => mapping(uint256 => mapping(bytes32 => Fact))) private _facts;
    /// @notice writer => tokenId => kind => ring slot => superseded fact.
    mapping(address => mapping(uint256 => mapping(bytes32 => mapping(uint256 => HistoryEntry)))) private _history;
    /// @notice writer => tokenId => kind => total supersessions (newest occupies (count - 1) % depth).
    mapping(address => mapping(uint256 => mapping(bytes32 => uint256))) private _historyCount;
    /// @notice writer => tokenId => the writer's lock on its own facts about that token.
    /// @dev Per token rather than per kind: the ticket's lock is "this writer's facts about this
    ///      token must not be used", which is a statement about the token, not about one field.
    mapping(address => mapping(uint256 => bool)) public locked;
    /// @notice writer => the writer's own floor; its facts stamped below it are dead.
    mapping(address => uint64) public minValidCycle;
    /// @notice writer => the writer's last cycle close.
    mapping(address => CycleClose) private _cycleCloses;
    /// @notice writer => the writer's declared limits on its own writes.
    mapping(address => WriterPolicy) private _policies;

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    /// @param historyDepth_ Superseded facts retained per row; 48 on the round-1 store.
    constructor(uint8 historyDepth_) {
        if (historyDepth_ == 0) revert HistoryDepthZero();
        historyDepth = historyDepth_;
    }

    // -------------------------------------------------------------------------
    // Writes — each one against the caller's own row, with no gate before it
    // -------------------------------------------------------------------------

    /// @notice Publish one fact under `writer`'s own row.
    /// @dev Does NOT close a cycle. Round 1 refreshed the heartbeat on every price write and the
    ///      ENG-3922 prototype copied that, but a cycle close means "I have finished this cycle",
    ///      and a writer that cannot write during cycle N without declaring N finished has no way
    ///      to run a cycle. `closeCycle` is the only thing that writes the cycle-close record.
    function writeFact(address writer, FactInput calldata input) external {
        _requireWriter(writer);
        uint64 nowTs = uint64(block.timestamp);
        uint64 valuedAt = input.valuedAt == 0 ? nowTs : input.valuedAt;
        if (valuedAt > nowTs) revert InvalidValuedAt(valuedAt, nowTs);
        uint64 floor = minValidCycle[writer];
        if (input.cycle < floor) revert CycleBelowFloor(floor, input.cycle);
        Fact storage current = _facts[writer][input.tokenId][input.kind];
        uint64 writtenAt = current.writtenAt;
        if (writtenAt != 0) {
            uint64 storedCycle = current.cycle;
            if (input.cycle < storedCycle) revert CycleNotMonotonic(storedCycle, input.cycle);
            // A row the writer has already killed by raising its own floor is a dead baseline: the
            // band and the interval are measured against a value the writer has disowned, so they
            // do not apply and the write is treated as a fresh first write. Round 1 did the same
            // (`_validatePriceWrite`'s `resetBaseline`).
            if (storedCycle >= floor) {
                _enforcePolicy(writer, current.value, input.value, writtenAt, nowTs);
            }
            // The superseded value is retained whether or not it is still valid; a consumer walking
            // history filters dead cycles itself, exactly as it does for the current fact.
            uint256 count = _historyCount[writer][input.tokenId][input.kind];
            _history[writer][input.tokenId][input.kind][count % historyDepth] =
                HistoryEntry({value: current.value, writtenAt: writtenAt, cycle: storedCycle});
            _historyCount[writer][input.tokenId][input.kind] = count + 1;
        }
        current.value = input.value;
        current.confidence = input.confidence;
        current.valuedAt = valuedAt;
        current.writtenAt = nowTs;
        current.cycle = input.cycle;
        current.data = input.data;
        emit FactWritten(
            writer, input.tokenId, input.kind, input.value, input.confidence, valuedAt, input.cycle, input.data
        );
    }

    /// @notice Record that `writer` has finished a cycle, carrying the cycle number and nothing else.
    /// @dev Non-decreasing: re-closing the current cycle refreshes the liveness timestamp without
    ///      claiming progress, which is what a writer with an unchanged book does. Going backwards
    ///      reverts.
    function closeCycle(address writer, uint64 cycle) external {
        _requireWriter(writer);
        uint64 floor = minValidCycle[writer];
        if (cycle < floor) revert CycleBelowFloor(floor, cycle);
        CycleClose storage close = _cycleCloses[writer];
        uint64 storedCycle = close.cycle;
        if (cycle < storedCycle) revert CycleNotMonotonic(storedCycle, cycle);
        uint64 nowTs = uint64(block.timestamp);
        close.cycle = cycle;
        close.closedAt = nowTs;
        emit CycleClosed(writer, cycle, nowTs);
    }

    /// @notice Lock or unlock `writer`'s own facts about a token.
    /// @dev The writer lock, which replaces round 1's central recovery-writer role. It takes effect
    ///      on the next read in the same block: `isFactLive` and `getLiveFact` consult it directly
    ///      and there is no pending or delayed state anywhere in this contract.
    function setLock(address writer, uint256 tokenId, bool value) external {
        _requireWriter(writer);
        locked[writer][tokenId] = value;
        emit LockSet(writer, tokenId, value);
    }

    /// @notice Raise `writer`'s own floor, killing every one of its facts stamped below it at once.
    /// @dev Strictly increasing: a call that would not move the floor is a mistake worth surfacing
    ///      rather than a silent no-op.
    function setMinValidCycle(address writer, uint64 newMinValidCycle) external {
        _requireWriter(writer);
        uint64 floor = minValidCycle[writer];
        if (newMinValidCycle <= floor) revert CycleNotMonotonic(floor, newMinValidCycle);
        minValidCycle[writer] = newMinValidCycle;
        emit MinValidCycleSet(writer, newMinValidCycle);
    }

    /// @notice Declare the limits `writer` holds its own writes to.
    /// @dev `maxDownBps` is capped at 100% because a larger figure has no meaning and would
    ///      underflow the floor of the band; `maxUpBps` is NOT capped, because a move of more than
    ///      2x is a real thing a writer may legitimately want to allow itself and this contract has
    ///      no authority to tell a writer its band is too wide. `minWriteInterval` of zero disables
    ///      the rate limit, and `bandDeclared` of false disables the band — a writer that has never
    ///      called this function is bound by neither.
    function declarePolicy(address writer, WriterPolicy calldata policy) external {
        _requireWriter(writer);
        if (policy.maxDownBps > BPS_DENOMINATOR) revert InvalidBand(policy.maxDownBps);
        _policies[writer] = policy;
        emit PolicyDeclared(writer, policy.maxUpBps, policy.maxDownBps, policy.minWriteInterval, policy.bandDeclared);
    }

    // -------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------

    /// @notice `writer`'s current fact, as stored, without judging it.
    /// @dev Raw storage: a caller using this MUST also consult `locked` and `minValidCycle`, or use
    ///      `getLiveFact`, which folds both in for one call instead of three.
    function getFact(address writer, uint256 tokenId, bytes32 kind) external view returns (Fact memory) {
        return _facts[writer][tokenId][kind];
    }

    /// @notice `writer`'s current fact together with whether it is still to be used.
    /// @dev The read an aggregator wants: presence, the writer's lock and the writer's floor in a
    ///      single external call.
    function getLiveFact(address writer, uint256 tokenId, bytes32 kind)
        external
        view
        returns (Fact memory fact, bool live)
    {
        fact = _facts[writer][tokenId][kind];
        live = fact.writtenAt != 0 && !locked[writer][tokenId] && fact.cycle >= minValidCycle[writer];
    }

    /// @notice Whether `writer`'s fact is present, unlocked and stamped at or above the writer's floor.
    function isFactLive(address writer, uint256 tokenId, bytes32 kind) external view returns (bool) {
        Fact storage fact = _facts[writer][tokenId][kind];
        return fact.writtenAt != 0 && !locked[writer][tokenId] && fact.cycle >= minValidCycle[writer];
    }

    /// @notice Whether a cycle number is at or above `writer`'s own floor.
    function isCycleValid(address writer, uint64 cycle) external view returns (bool) {
        return cycle >= minValidCycle[writer];
    }

    /// @notice `writer`'s last cycle close: the cycle number and when it was recorded.
    function lastCycleClose(address writer) external view returns (CycleClose memory) {
        return _cycleCloses[writer];
    }

    /// @notice The limits `writer` has declared for its own writes.
    function policyOf(address writer) external view returns (WriterPolicy memory) {
        return _policies[writer];
    }

    /// @notice Superseded facts retained for a row, capped at `historyDepth`.
    function historyLength(address writer, uint256 tokenId, bytes32 kind) external view returns (uint256) {
        uint256 count = _historyCount[writer][tokenId][kind];
        uint256 depth = historyDepth;
        return count < depth ? count : depth;
    }

    /// @notice A superseded fact, newest first; index 0 is the value the current fact replaced.
    function getHistory(address writer, uint256 tokenId, bytes32 kind, uint256 index)
        external
        view
        returns (HistoryEntry memory)
    {
        uint256 count = _historyCount[writer][tokenId][kind];
        uint256 depth = historyDepth;
        uint256 len = count < depth ? count : depth;
        if (index >= len) revert HistoryIndexOutOfBounds(index, len);
        return _history[writer][tokenId][kind][(count - 1 - index) % depth];
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _requireWriter(address writer) internal view {
        if (writer != msg.sender) revert NotWriter(writer, msg.sender);
    }

    /// @dev The writer's own rate limit and band, applied to a write that supersedes a live value.
    function _enforcePolicy(address writer, uint128 lastValue, uint128 newValue, uint64 writtenAt, uint64 nowTs)
        internal
        view
    {
        WriterPolicy memory policy = _policies[writer];
        if (policy.minWriteInterval != 0) {
            // Widened so a writer declaring a very long interval cannot overflow the comparison.
            if (uint256(nowTs) < uint256(writtenAt) + uint256(policy.minWriteInterval)) {
                revert WriteTooSoon(writtenAt, policy.minWriteInterval, nowTs);
            }
        }
        if (!policy.bandDeclared) return;
        uint256 last = uint256(lastValue);
        uint256 maxUp = last + (last * uint256(policy.maxUpBps)) / uint256(BPS_DENOMINATOR);
        uint256 maxDown = last - (last * uint256(policy.maxDownBps)) / uint256(BPS_DENOMINATOR);
        if (uint256(newValue) > maxUp || uint256(newValue) < maxDown) {
            revert BandExceeded(lastValue, newValue, policy.maxUpBps, policy.maxDownBps);
        }
    }
}
