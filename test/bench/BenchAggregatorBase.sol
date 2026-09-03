// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice ENG-3922 harness — the aggregator, with the fact layer left abstract.
/// @dev One aggregator, one check-set, one evaluation order; each arm supplies only the
///      fact-layer reads. The hooks are `internal virtual`, not an external adapter contract,
///      on purpose: an external adapter would add the same call overhead to every arm and
///      bury the thing being measured. Swapping arms is swapping the subclass.
///
///      Evaluation order follows the deployed `FabricaOracleAggregator`: currency → heartbeat
///      → lock → live sources with the rate-of-change breaker → MIN → dispersion → temporal
///      floor. Two round-1 gates are gone by round-2 decision, not by omission: the per-token
///      `register` gate (Part A item 2, "there is no registry of tokens") and the recovery
///      status (Part A item 3, replaced by the writer lock).
///
///      Config is immutable, per round-2 position 3: a rule change is a new aggregator.
abstract contract BenchAggregatorBase is IPriceOracle {
    struct PriceFact {
        bool present;
        uint128 priceUsdc6;
        uint64 lastWrittenAt;
        uint64 cycle;
    }

    uint16 public constant BPS_DENOMINATOR = 10_000;

    bytes32 public constant CHECK_CURRENCY = keccak256("currency");
    bytes32 public constant CHECK_HEARTBEAT = keccak256("heartbeat");
    bytes32 public constant CHECK_LOCK = keccak256("lock");
    bytes32 public constant CHECK_MIN_SOURCES = keccak256("min_sources");
    bytes32 public constant CHECK_DISPERSION = keccak256("dispersion");

    /// @notice Only accepted currency.
    address public immutable usdc;
    /// @notice Asymmetric seasoning window. Increases wait it out; decreases count at once.
    uint64 public immutable seasoningWindow;
    /// @notice Max inter-publication jump in bps before an oracle source is dropped.
    uint16 public immutable maxJumpBps;
    /// @notice Max allowed max/min across live oracle sources, in bps.
    uint16 public immutable maxDispersionBps;
    /// @notice Minimum live oracle sources after the breaker.
    uint8 public immutable minLiveSources;
    /// @notice Longest gap since a writer's heartbeat that still counts as live.
    uint64 public immutable maxSilence;
    /// @notice Number of oracle sources this aggregator reads. The harness runs three.
    uint8 public constant SOURCE_COUNT = 3;

    error InvalidLength();
    error ZeroQuantity(uint256 index);
    error CheckFailed(bytes32 checkId);
    error InvalidConfig();

    constructor(
        address usdc_,
        uint64 seasoningWindow_,
        uint16 maxJumpBps_,
        uint16 maxDispersionBps_,
        uint8 minLiveSources_,
        uint64 maxSilence_
    ) {
        if (usdc_ == address(0)) revert InvalidConfig();
        if (minLiveSources_ < 2) revert InvalidConfig();
        if (maxJumpBps_ == 0) revert InvalidConfig();
        if (maxDispersionBps_ < BPS_DENOMINATOR) revert InvalidConfig();
        usdc = usdc_;
        seasoningWindow = seasoningWindow_;
        maxJumpBps = maxJumpBps_;
        maxDispersionBps = maxDispersionBps_;
        minLiveSources = minLiveSources_;
        maxSilence = maxSilence_;
    }

    // -------------------------------------------------------------------------
    // Fact-layer hooks — the only thing an arm implements
    // -------------------------------------------------------------------------

    /// @notice The oracle source's current price fact, already checked for liveness by the arm.
    function _current(uint8 sourceId, uint256 tokenId, bytes calldata oracleContext)
        internal
        view
        virtual
        returns (PriceFact memory);

    /// @notice The price this oracle source published immediately before the current one.
    function _previous(uint8 sourceId, uint256 tokenId, bytes calldata oracleContext)
        internal
        view
        virtual
        returns (PriceFact memory);

    /// @notice This oracle source's price as of `targetTs`, and how many hops it took to find it.
    function _asOf(uint8 sourceId, uint256 tokenId, uint64 targetTs, bytes calldata oracleContext)
        internal
        view
        virtual
        returns (bool found, uint128 priceUsdc6, uint256 hops);

    /// @notice Whether this oracle source's writer has heartbeat within `maxSilence`.
    function _heartbeatFresh(uint8 sourceId) internal view virtual returns (bool);

    /// @notice Whether this oracle source's writer has locked its own facts about the token.
    function _isLocked(uint8 sourceId, uint256 tokenId, bytes calldata oracleContext)
        internal
        view
        virtual
        returns (bool);

    // -------------------------------------------------------------------------
    // IPriceOracle
    // -------------------------------------------------------------------------

    /// @inheritdoc IPriceOracle
    function price(
        address, /* collateralToken */
        address currencyToken,
        uint256[] memory tokenIds,
        uint256[] memory tokenIdQuantities,
        bytes calldata oracleContext
    ) external view override returns (uint256) {
        if (tokenIds.length != tokenIdQuantities.length) revert InvalidLength();
        if (tokenIds.length == 0) revert InvalidLength();
        uint256 total;
        uint256 count;
        for (uint256 i; i < tokenIds.length; ++i) {
            if (tokenIdQuantities[i] == 0) revert ZeroQuantity(i);
            (bool pass, bytes32 checkId, uint256 usable,) = _evaluate(currencyToken, tokenIds[i], oracleContext);
            if (!pass) revert CheckFailed(checkId);
            total += usable * tokenIdQuantities[i];
            count += tokenIdQuantities[i];
        }
        return total / count;
    }

    /// @notice Per-check visibility, plus the seasoning walk depth the read actually needed.
    function eligibilityReport(address currencyToken, uint256 tokenId, bytes calldata oracleContext)
        external
        view
        returns (bool ok, bytes32 failedCheck, uint256 usable, uint256 walkHops)
    {
        return _evaluate(currencyToken, tokenId, oracleContext);
    }

    // -------------------------------------------------------------------------
    // Internals — identical across arms
    // -------------------------------------------------------------------------

    function _evaluate(address currencyToken, uint256 tokenId, bytes calldata oracleContext)
        internal
        view
        returns (bool pass, bytes32 failedCheck, uint256 usable, uint256 walkHops)
    {
        if (currencyToken != usdc) return (false, CHECK_CURRENCY, 0, 0);
        (uint256 liveCount, uint128 currentMin, uint128 currentMax, bool anyLive) =
            _collectLiveMinMax(tokenId, oracleContext);
        if (!anyLive) return (false, CHECK_HEARTBEAT, 0, 0);
        if (liveCount < uint256(minLiveSources) || currentMin == 0) return (false, CHECK_MIN_SOURCES, 0, 0);
        uint256 ratioBps = (uint256(currentMax) * uint256(BPS_DENOMINATOR)) / uint256(currentMin);
        if (ratioBps > uint256(maxDispersionBps)) return (false, CHECK_DISPERSION, 0, 0);
        (uint128 usablePrice, uint256 hops) = _applyTemporalFloor(tokenId, currentMin, oracleContext);
        return (true, bytes32(0), uint256(usablePrice), hops);
    }

    function _collectLiveMinMax(uint256 tokenId, bytes calldata oracleContext)
        internal
        view
        returns (uint256 liveCount, uint128 currentMin, uint128 currentMax, bool anyHeartbeat)
    {
        currentMin = type(uint128).max;
        for (uint8 sid; sid < SOURCE_COUNT; ++sid) {
            if (!_heartbeatFresh(sid)) continue;
            anyHeartbeat = true;
            if (_isLocked(sid, tokenId, oracleContext)) continue;
            PriceFact memory cur = _current(sid, tokenId, oracleContext);
            if (!cur.present || cur.priceUsdc6 == 0) continue;
            if (_trippedBreaker(sid, tokenId, cur, oracleContext)) continue;
            if (cur.priceUsdc6 < currentMin) currentMin = cur.priceUsdc6;
            if (cur.priceUsdc6 > currentMax) currentMax = cur.priceUsdc6;
            unchecked {
                ++liveCount;
            }
        }
        if (liveCount == 0) {
            currentMin = 0;
            currentMax = 0;
        }
    }

    function _applyTemporalFloor(uint256 tokenId, uint128 currentMin, bytes calldata oracleContext)
        internal
        view
        returns (uint128 usablePrice, uint256 walkHops)
    {
        usablePrice = currentMin;
        if (seasoningWindow == 0) return (usablePrice, 0);
        uint64 targetTs = uint64(block.timestamp) > seasoningWindow ? uint64(block.timestamp) - seasoningWindow : 0;
        uint128 pastMin = type(uint128).max;
        bool any;
        for (uint8 sid; sid < SOURCE_COUNT; ++sid) {
            if (!_heartbeatFresh(sid)) continue;
            if (_isLocked(sid, tokenId, oracleContext)) continue;
            PriceFact memory cur = _current(sid, tokenId, oracleContext);
            if (!cur.present || cur.priceUsdc6 == 0) continue;
            if (_trippedBreaker(sid, tokenId, cur, oracleContext)) continue;
            (bool found, uint128 p, uint256 hops) = _asOf(sid, tokenId, targetTs, oracleContext);
            walkHops += hops;
            if (!found) continue;
            if (p < pastMin) pastMin = p;
            any = true;
        }
        if (any && pastMin < usablePrice) usablePrice = pastMin;
    }

    /// @notice Rate-of-change breaker: drop an oracle source whose jump from its prior
    ///         publication exceeds `maxJumpBps`.
    function _trippedBreaker(uint8 sourceId, uint256 tokenId, PriceFact memory current, bytes calldata oracleContext)
        internal
        view
        returns (bool)
    {
        if (maxJumpBps == 0) return false;
        PriceFact memory prev = _previous(sourceId, tokenId, oracleContext);
        if (!prev.present || prev.priceUsdc6 == 0) return false;
        uint256 cur = uint256(current.priceUsdc6);
        uint256 prv = uint256(prev.priceUsdc6);
        uint256 hi = cur > prv ? cur : prv;
        uint256 lo = cur > prv ? prv : cur;
        return ((hi - lo) * uint256(BPS_DENOMINATOR)) / prv > uint256(maxJumpBps);
    }
}
