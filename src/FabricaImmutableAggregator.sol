// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IFabricaFactStore} from "./interfaces/IFabricaFactStore.sol";

/// @notice Round-2 immutable aggregator: turns the round-2 fact store's facts about a token into one
///         lendable price, or a refusal naming the check that failed.
/// @dev Replaces `FabricaOracleAggregator` (round 1, ENG-3519) rather than upgrading it; the round-1
///      aggregator stays deployed and serving its own pool. Round-2 proposal Part A item 5, ruled by
///      Tim on 3 September 2026: the trusted writer set and every threshold are fixed at deploy so
///      lenders can rely on the rules not moving under their deposits.
///
///      **There is no owner, no setter, no freeze step and nothing to renounce.** Round 1 shipped an
///      `Ownable2Step` pre-freeze owner path (`setFactStore`, `setUsdc`, `setValidatorId`,
///      `setSourceIds`, `setKnobs`, `setLandUsePolicy`) plus an opt-in `renounceAggregator()`, so the
///      rules were mutable until someone remembered to freeze them. Here every parameter is an
///      `immutable` written by the constructor into the deployed bytecode. A rule change is a new
///      aggregator and a new pool; that is the only evolution path.
///
///      The trusted writer set is held in `immutable` slots rather than a storage array. Storage
///      written only by a constructor would be equally unchangeable, but immutables put the addresses
///      in the code itself — a reviewer can read them out of the verified source with no storage
///      probe — and they save a cold `SLOAD` per writer inside `price()`, which sits on the pool's
///      borrow path.
///
///      Round-2 rules (Tim, 3 September 2026 18:47Z and 18:50Z; the earlier Merkle-root and coverage
///      paragraphs on ENG-3925 are history):
///      * Per trusted writer and token, the newest unrevoked valuation is the only one considered.
///      * A lock, a revocation or a newer write invalidates prior state immediately — the store folds
///        all three into `getLiveFact`, and nothing here caches.
///      * The writer's last cycle close must be within `maxSilence`.
///      * Nothing is supplied per read and nothing is computed per quote: `oracleContext` is unused.
///      * No root, no proof, no coverage check. A token a writer stops covering is that writer's lock
///        or revocation to send (fail-open by design this round).
///
///      The read interface stays MetaStreet `IPriceOracle`, so the pool's upstream code is unchanged.
contract FabricaImmutableAggregator is IPriceOracle {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The `kind` under which oracle sources publish valuations, in USDC 1e6.
    /// @dev Pinned against the live store in the constructor, so a store of the wrong shape — or the
    ///      round-1 store, which has no `KIND_PRICE` at all — cannot be wired in silently.
    bytes32 public constant KIND_PRICE = keccak256("fabrica.fact.price");

    /// @notice Upper bound on the trusted writer set, fixed by the number of immutable slots below.
    /// @dev Eight is well above the three oracle sources round 2 trusts (Prycd, OpenAVM, Regrid
    ///      assessor) and keeps `price()`'s two scans bounded by construction.
    uint256 public constant MAX_TRUSTED_WRITERS = 8;

    /// @notice Check id: currency is not the configured USDC.
    bytes32 public constant CHECK_CURRENCY = keccak256("currency");
    /// @notice Check id: fewer than `minLiveSources` trusted writers have a recent, valid cycle close.
    bytes32 public constant CHECK_MAX_SILENCE = keccak256("max_silence");
    /// @notice Check id: fewer than `minLiveSources` usable valuations after every filter.
    bytes32 public constant CHECK_MIN_SOURCES = keccak256("min_sources");
    /// @notice Check id: dispersion (max/min) exceeded.
    bytes32 public constant CHECK_DISPERSION = keccak256("dispersion");

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice Every constructor argument, in one struct so the deploy site reads as named fields.
    struct Config {
        address factStore;
        address usdc;
        address[] writers;
        uint8 minLiveSources;
        uint64 maxSilence;
        uint64 cycleCloseInterval;
        uint64 seasoningWindow;
        uint16 maxJumpBps;
        uint16 maxDispersionBps;
        uint128 maxFirstPriceUsdc6;
        uint128 valueCeilingUsdc6;
    }

    /// @notice One trusted writer's contribution to a token's price, after every round-2 filter.
    /// @dev `fresh` and `live` are separate answers to separate questions. A writer can be perfectly
    ///      live as a feed (a recent, valid cycle close) and still hold no usable valuation for one
    ///      token — it locked that token, or its value is out of bounds. Keeping them apart is what
    ///      lets `eligibilityReport` say `max_silence` when the feeds are dark and `min_sources` when
    ///      the feeds are up but this token is not priceable.
    struct Valuation {
        bool fresh;
        bool live;
        uint128 value;
        uint64 writtenAt;
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidConfig();
    error InvalidWriterSet();
    error DuplicateWriter(address writer);
    error UnexpectedFactStoreKind(bytes32 expected, bytes32 found);
    error WriterIndexOutOfBounds(uint256 index, uint256 length);
    error InvalidLength();
    error ZeroQuantity(uint256 index);
    error CheckFailed(bytes32 checkId);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice The complete rule set this aggregator will hold for its whole life.
    /// @dev Emitted once, from the constructor. It is the only write this contract will ever make to
    ///      the log, and it exists so the deployed parameters can be read from an indexer without an
    ///      archive node and without trusting the deploy script's own console output.
    event AggregatorDeployed(
        address indexed factStore,
        address indexed usdc,
        address[] writers,
        uint8 minLiveSources,
        uint64 maxSilence,
        uint64 cycleCloseInterval,
        uint64 seasoningWindow,
        uint16 maxJumpBps,
        uint16 maxDispersionBps,
        uint128 maxFirstPriceUsdc6,
        uint128 valueCeilingUsdc6
    );

    // -------------------------------------------------------------------------
    // Immutable configuration
    // -------------------------------------------------------------------------

    /// @notice Round-2 permissionless fact store (ENG-3924).
    IFabricaFactStore public immutable factStore;
    /// @notice The only accepted currency (USDC).
    address public immutable usdc;
    /// @notice Number of trusted writers actually configured.
    uint8 public immutable writerCount;
    /// @notice Valuations required before a token can be priced at all.
    uint8 public immutable minLiveSources;
    /// @notice Longest gap since a writer's last cycle close that still counts as a live feed.
    uint64 public immutable maxSilence;
    /// @notice The cycle-close cadence `maxSilence` was sized against. Nothing branches on it.
    /// @dev Tim's number for round 2 is a daily cycle close, and `maxSilence` is three days — three
    ///      cadences, so a writer misses two closes before its feed goes dark. The aggregator cannot
    ///      enforce a writer's cadence (only the writer decides when it closes a cycle), so this is
    ///      published rather than checked: it puts the assumption behind `maxSilence` on chain where
    ///      a lender can read it, instead of leaving it in a ticket.
    uint64 public immutable cycleCloseInterval;
    /// @notice Asymmetric seasoning window. An increase must age through it; a decrease counts at once.
    uint64 public immutable seasoningWindow;
    /// @notice Rate-of-change breaker: largest move from the previous valuation before a feed is dropped.
    uint16 public immutable maxJumpBps;
    /// @notice Dispersion breaker: largest max/min across live valuations, in bps of the min.
    uint16 public immutable maxDispersionBps;
    /// @notice Guard 8, re-established from the round-1 store: cap on a writer's FIRST valuation for a row.
    uint128 public immutable maxFirstPriceUsdc6;
    /// @notice Guard 9, re-established from the round-1 store: ceiling on any valuation.
    uint128 public immutable valueCeilingUsdc6;

    address private immutable _writer0;
    address private immutable _writer1;
    address private immutable _writer2;
    address private immutable _writer3;
    address private immutable _writer4;
    address private immutable _writer5;
    address private immutable _writer6;
    address private immutable _writer7;

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    constructor(Config memory config) {
        _validate(config);
        factStore = IFabricaFactStore(config.factStore);
        usdc = config.usdc;
        writerCount = uint8(config.writers.length);
        minLiveSources = config.minLiveSources;
        maxSilence = config.maxSilence;
        cycleCloseInterval = config.cycleCloseInterval;
        seasoningWindow = config.seasoningWindow;
        maxJumpBps = config.maxJumpBps;
        maxDispersionBps = config.maxDispersionBps;
        maxFirstPriceUsdc6 = config.maxFirstPriceUsdc6;
        valueCeilingUsdc6 = config.valueCeilingUsdc6;
        _writer0 = _configuredWriter(config.writers, 0);
        _writer1 = _configuredWriter(config.writers, 1);
        _writer2 = _configuredWriter(config.writers, 2);
        _writer3 = _configuredWriter(config.writers, 3);
        _writer4 = _configuredWriter(config.writers, 4);
        _writer5 = _configuredWriter(config.writers, 5);
        _writer6 = _configuredWriter(config.writers, 6);
        _writer7 = _configuredWriter(config.writers, 7);
        emit AggregatorDeployed(
            config.factStore,
            config.usdc,
            config.writers,
            config.minLiveSources,
            config.maxSilence,
            config.cycleCloseInterval,
            config.seasoningWindow,
            config.maxJumpBps,
            config.maxDispersionBps,
            config.maxFirstPriceUsdc6,
            config.valueCeilingUsdc6
        );
    }

    // -------------------------------------------------------------------------
    // IPriceOracle
    // -------------------------------------------------------------------------

    /// @inheritdoc IPriceOracle
    /// @dev `oracleContext` is unused and must stay so: Tim ruled proof-at-read out on 3 September
    ///      2026 18:44Z because buy-now-pay-later calldata is fixed days before execution, so nothing
    ///      is supplied per read and nothing is computed per quote. USDC 1e6 per unit of supply.
    ///      Evaluation order: currency -> maximum silence -> live valuations + breakers -> MIN ->
    ///      dispersion -> temporal floor.
    function price(
        address, /* collateralToken */
        address currencyToken,
        uint256[] memory tokenIds,
        uint256[] memory tokenIdQuantities,
        bytes calldata /* oracleContext */
    ) external view override returns (uint256) {
        if (tokenIds.length != tokenIdQuantities.length) revert InvalidLength();
        if (tokenIds.length == 0) revert InvalidLength();
        uint256 total;
        uint256 count;
        for (uint256 i; i < tokenIds.length; ++i) {
            if (tokenIdQuantities[i] == 0) revert ZeroQuantity(i);
            (bool pass, bytes32 checkId, uint256 unit) = _evaluate(currencyToken, tokenIds[i]);
            if (!pass) revert CheckFailed(checkId);
            total += unit * tokenIdQuantities[i];
            count += tokenIdQuantities[i];
        }
        return total / count;
    }

    // -------------------------------------------------------------------------
    // Observability
    // -------------------------------------------------------------------------

    /// @notice Explain eligibility for a single token without reverting.
    /// @return ok True if `price` would succeed for quantity 1 of this token in USDC.
    /// @return failedCheck The check that refused, or `bytes32(0)` when `ok`.
    function eligibilityReport(address currencyToken, uint256 tokenId)
        external
        view
        returns (bool ok, bytes32 failedCheck)
    {
        (bool pass, bytes32 checkId,) = _evaluate(currencyToken, tokenId);
        return (pass, checkId);
    }

    /// @notice The trusted writer set, in the order it was configured at deploy.
    function writers() external view returns (address[] memory set) {
        uint256 n = writerCount;
        set = new address[](n);
        for (uint256 i; i < n; ++i) {
            set[i] = _writerAt(i);
        }
    }

    /// @notice One trusted writer by index.
    function writerAt(uint256 index) external view returns (address) {
        if (index >= writerCount) revert WriterIndexOutOfBounds(index, writerCount);
        return _writerAt(index);
    }

    /// @notice Whether `writer` is one of the addresses this aggregator trusts.
    function isTrustedWriter(address writer) external view returns (bool) {
        if (writer == address(0)) return false;
        uint256 n = writerCount;
        for (uint256 i; i < n; ++i) {
            if (_writerAt(i) == writer) return true;
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Internals — evaluation
    // -------------------------------------------------------------------------

    function _evaluate(address currencyToken, uint256 tokenId)
        internal
        view
        returns (bool pass, bytes32 failedCheck, uint256 usable)
    {
        if (currencyToken != usdc) {
            return (false, CHECK_CURRENCY, 0);
        }
        uint256 freshCount;
        uint256 liveCount;
        uint128 currentMin = type(uint128).max;
        uint128 currentMax;
        uint256 n = writerCount;
        // Collected once and handed to the temporal floor. Recomputing them there would double every
        // fact-store call this read makes, and `price()` is on the pool's quote and borrow path.
        Valuation[] memory valuations = new Valuation[](n);
        for (uint256 i; i < n; ++i) {
            valuations[i] = _valuationOf(_writerAt(i), tokenId);
            if (valuations[i].fresh) ++freshCount;
            if (!valuations[i].live) continue;
            ++liveCount;
            if (valuations[i].value < currentMin) currentMin = valuations[i].value;
            if (valuations[i].value > currentMax) currentMax = valuations[i].value;
        }
        // Reported before min_sources so a dark feed is never mistaken for an unpriceable token: a
        // lender reading `max_silence` knows to look at the writers, not at this token.
        if (freshCount < uint256(minLiveSources)) {
            return (false, CHECK_MAX_SILENCE, 0);
        }
        if (liveCount < uint256(minLiveSources) || currentMin == 0) {
            return (false, CHECK_MIN_SOURCES, 0);
        }
        uint256 ratioBps = (uint256(currentMax) * uint256(BPS_DENOMINATOR)) / uint256(currentMin);
        if (ratioBps > uint256(maxDispersionBps)) {
            return (false, CHECK_DISPERSION, 0);
        }
        return (true, bytes32(0), uint256(_applyTemporalFloor(tokenId, currentMin, valuations)));
    }

    /// @notice One writer's valuation of one token, after every round-2 filter.
    function _valuationOf(address writer, uint256 tokenId) internal view returns (Valuation memory valuation) {
        IFabricaFactStore store = factStore;
        IFabricaFactStore.CycleClose memory close = store.lastCycleClose(writer);
        // A writer that has never closed a cycle has never declared a book, so it is silent rather
        // than merely quiet. Liveness is never inferred from a fact's `writtenAt`: a fact write does
        // not close a cycle, and ENG-3924 is explicit that a consumer must not conflate the two.
        if (close.closedAt == 0) return valuation;
        if (block.timestamp > uint256(close.closedAt) + uint256(maxSilence)) return valuation;
        // `closeCycle` refuses a cycle below the writer's floor at the time of the call, but raising
        // the floor afterwards does not rewrite the recorded close, so a close can name a cycle the
        // writer has since killed. Per the ENG-3924 handoff, check both.
        if (!store.isCycleValid(writer, close.cycle)) return valuation;
        valuation.fresh = true;
        (IFabricaFactStore.Fact memory fact, bool live) = store.getLiveFact(writer, tokenId, KIND_PRICE);
        // `live` folds presence, the writer's lock and the writer's floor. A newer write supersedes
        // by overwriting the row, so "newest unrevoked valuation" needs no extra work here.
        if (!live) return valuation;
        // Guard 4, moved from the round-1 store: a zero price is treated as absent. The round-2 store
        // uses `writtenAt` as its presence marker and does not interpret `kind`, so it cannot know
        // which kinds are prices; this is the aggregator's to enforce.
        if (fact.value == 0) return valuation;
        // Guard 9, re-established here: the round-2 store dropped the global value ceiling.
        if (fact.value > valueCeilingUsdc6) return valuation;
        uint256 historyLength = store.historyLength(writer, tokenId, KIND_PRICE);
        if (historyLength == 0) {
            // Guard 8, re-established here: no supersession means this is the writer's first
            // valuation for the row, which is exactly what the round-1 first-price cap bounded.
            if (fact.value > maxFirstPriceUsdc6) return valuation;
        } else if (_breakerTripped(store, writer, tokenId, fact.value)) {
            return valuation;
        }
        valuation.live = true;
        valuation.value = fact.value;
        valuation.writtenAt = fact.writtenAt;
    }

    /// @notice Rate-of-change breaker: drop a feed whose jump from its previous valuation is too large.
    function _breakerTripped(IFabricaFactStore store, address writer, uint256 tokenId, uint128 value)
        internal
        view
        returns (bool)
    {
        IFabricaFactStore.HistoryEntry memory previous = store.getHistory(writer, tokenId, KIND_PRICE, 0);
        if (previous.value == 0) return false;
        // A raised floor disowns old baselines; the first valid rewrite starts a new breaker baseline.
        if (!store.isCycleValid(writer, previous.cycle)) return false;
        uint256 current = uint256(value);
        uint256 prior = uint256(previous.value);
        uint256 high = current > prior ? current : prior;
        uint256 low = current > prior ? prior : current;
        uint256 jumpBps = ((high - low) * uint256(BPS_DENOMINATOR)) / prior;
        return jumpBps > uint256(maxJumpBps);
    }

    /// @notice Asymmetric seasoning: an increase must age through the window, a decrease counts at once.
    /// @param valuations The valuations `_evaluate` already collected, indexed by writer position.
    function _applyTemporalFloor(uint256 tokenId, uint128 currentMin, Valuation[] memory valuations)
        internal
        view
        returns (uint128 usable)
    {
        usable = currentMin;
        if (seasoningWindow == 0) return usable;
        uint64 targetTs = uint64(block.timestamp) > seasoningWindow ? uint64(block.timestamp) - seasoningWindow : 0;
        uint128 pastMin = type(uint128).max;
        bool anyPast;
        uint256 n = valuations.length;
        for (uint256 i; i < n; ++i) {
            if (!valuations[i].live) continue;
            (bool found, uint128 pastValue) = _valueAsOf(_writerAt(i), tokenId, valuations[i], targetTs);
            if (!found) continue;
            if (pastValue < pastMin) pastMin = pastValue;
            anyPast = true;
        }
        if (anyPast && pastMin < usable) {
            usable = pastMin;
        }
    }

    /// @notice A writer's valuation as of `targetTs`, from its current fact and then its history.
    function _valueAsOf(address writer, uint256 tokenId, Valuation memory valuation, uint64 targetTs)
        internal
        view
        returns (bool found, uint128 value)
    {
        // Trusted wall-clock write time only — never the writer-supplied `valuedAt`.
        if (valuation.writtenAt != 0 && valuation.writtenAt <= targetTs) {
            return (true, valuation.value);
        }
        IFabricaFactStore store = factStore;
        uint256 length = store.historyLength(writer, tokenId, KIND_PRICE);
        // Newest first, so the first entry at or before the cutoff is the one in force then.
        for (uint256 i; i < length; ++i) {
            IFabricaFactStore.HistoryEntry memory entry = store.getHistory(writer, tokenId, KIND_PRICE, i);
            if (entry.value == 0) continue;
            if (entry.writtenAt == 0) continue;
            if (!store.isCycleValid(writer, entry.cycle)) continue;
            if (entry.writtenAt <= targetTs) {
                return (true, entry.value);
            }
        }
        return (false, 0);
    }

    // -------------------------------------------------------------------------
    // Internals — configuration
    // -------------------------------------------------------------------------

    /// @dev Split by subject rather than kept as one list: the wiring, the writer set and the
    ///      thresholds fail for different reasons and a reader checking one of them should not have
    ///      to walk the other two.
    function _validate(Config memory config) internal view {
        _validateWiring(config);
        _validateWriters(config);
        _validateThresholds(config);
    }

    function _validateWiring(Config memory config) internal view {
        if (config.factStore == address(0) || config.usdc == address(0)) revert ZeroAddress();
        if (config.factStore.code.length == 0 || config.usdc.code.length == 0) revert InvalidConfig();
        bytes32 storeKind = IFabricaFactStore(config.factStore).KIND_PRICE();
        if (storeKind != KIND_PRICE) revert UnexpectedFactStoreKind(KIND_PRICE, storeKind);
    }

    function _validateWriters(Config memory config) internal pure {
        uint256 n = config.writers.length;
        if (n == 0 || n > MAX_TRUSTED_WRITERS) revert InvalidWriterSet();
        for (uint256 i; i < n; ++i) {
            if (config.writers[i] == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < n; ++j) {
                if (config.writers[i] == config.writers[j]) revert DuplicateWriter(config.writers[i]);
            }
        }
        if (n < config.minLiveSources) revert InvalidWriterSet();
    }

    function _validateThresholds(Config memory config) internal pure {
        // The round-1 floor, kept: a single valuation is one writer's unchecked word, and MIN across
        // one source is not an aggregation. There is no owner here to lower it later either way.
        if (config.minLiveSources < 2) revert InvalidConfig();
        if (config.maxSilence == 0) revert InvalidConfig();
        if (config.cycleCloseInterval == 0) revert InvalidConfig();
        if (config.maxJumpBps == 0) revert InvalidConfig();
        // Must permit at least 1.0x, or no two valuations could ever agree closely enough.
        if (config.maxDispersionBps < BPS_DENOMINATOR) revert InvalidConfig();
        if (config.maxFirstPriceUsdc6 == 0 || config.valueCeilingUsdc6 == 0) revert InvalidConfig();
        // Round-1's `_validateKnobs` rule: a first-price cap above the ceiling is unreachable.
        if (config.maxFirstPriceUsdc6 > config.valueCeilingUsdc6) revert InvalidConfig();
    }

    function _configuredWriter(address[] memory set, uint256 index) internal pure returns (address) {
        return index < set.length ? set[index] : address(0);
    }

    function _writerAt(uint256 index) internal view returns (address) {
        if (index == 0) return _writer0;
        if (index == 1) return _writer1;
        if (index == 2) return _writer2;
        if (index == 3) return _writer3;
        if (index == 4) return _writer4;
        if (index == 5) return _writer5;
        if (index == 6) return _writer6;
        return _writer7;
    }
}
