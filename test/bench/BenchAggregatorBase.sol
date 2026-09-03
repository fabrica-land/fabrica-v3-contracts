// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice ENG-3922 harness — the aggregator, with the fact layer left abstract.
/// @dev One aggregator, one check-set, one evaluation order; each arm supplies only the
///      fact-layer reads. The hooks are `internal virtual`, not an external adapter contract,
///      on purpose: an external adapter would add the same call overhead to every arm and bury
///      the thing being measured. Swapping arms is swapping the subclass.
///
///      Evaluation order follows the deployed `FabricaOracleAggregator`: currency → writer
///      liveness → lock → Merkle membership → live sources with the rate-of-change breaker →
///      MIN → dispersion → temporal floor. Two round-1 gates are gone by round-2 decision, not
///      by omission: the per-token `register` gate (Part A item 2) and the recovery status
///      (Part A item 3, replaced by the writer lock).
///
///      Config is immutable, per round-2 position 3: a rule change is a new aggregator.
abstract contract BenchAggregatorBase is IPriceOracle {
    /// @notice The aggregator's immutable rule set, grouped so subclasses stay shallow.
    struct AggConfig {
        address usdc;
        uint64 seasoningWindow;
        uint16 maxJumpBps;
        uint16 maxDispersionBps;
        uint8 minLiveSources;
        uint64 maxSilence;
        bool requireMerkleProof;
    }

    struct PriceFact {
        bool present;
        uint128 priceUsdc6;
        uint64 lastWrittenAt;
        uint64 cycle;
    }

    /// @notice Everything a caller may pass through `oracleContext`, decoded once per read.
    /// @dev `priceUids` and `heartbeatUids` are Option C's caller-supplied attestation uids and
    ///      are ignored by every arm that has an on-chain lookup. `proofs` is indexed
    ///      `[tokenIndex * SOURCE_COUNT + sourceId]` so a basket carries one proof per token per
    ///      oracle source.
    struct Ctx {
        bytes32[3] priceUids;
        bytes32[3] heartbeatUids;
        bytes32[][] proofs;
        uint256 tokenIndex;
    }

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant SOURCE_COUNT = 3;

    bytes32 public constant CHECK_CURRENCY = keccak256("currency");
    bytes32 public constant CHECK_HEARTBEAT = keccak256("heartbeat");
    bytes32 public constant CHECK_LOCK = keccak256("lock");
    bytes32 public constant CHECK_ROOT = keccak256("root");
    bytes32 public constant CHECK_MIN_SOURCES = keccak256("min_sources");
    bytes32 public constant CHECK_DISPERSION = keccak256("dispersion");

    address public immutable usdc;
    uint64 public immutable seasoningWindow;
    uint16 public immutable maxJumpBps;
    uint16 public immutable maxDispersionBps;
    uint8 public immutable minLiveSources;
    uint64 public immutable maxSilence;

    /// @notice Whether a valuation must be proven under its writer's Merkle root.
    /// @dev Tim, 3 September 18:17Z: the aggregator refuses a valuation for a token that is not
    ///      proven under the writer's root. Switchable only so the experiment can price the rule
    ///      — every published arm number is measured with it on.
    bool public immutable requireMerkleProof;

    error InvalidLength();
    error ZeroQuantity(uint256 index);
    error CheckFailed(bytes32 checkId);
    error InvalidConfig();

    constructor(AggConfig memory cfg) {
        if (cfg.usdc == address(0)) revert InvalidConfig();
        if (cfg.minLiveSources < 2) revert InvalidConfig();
        if (cfg.maxJumpBps == 0) revert InvalidConfig();
        if (cfg.maxDispersionBps < BPS_DENOMINATOR) revert InvalidConfig();
        usdc = cfg.usdc;
        seasoningWindow = cfg.seasoningWindow;
        maxJumpBps = cfg.maxJumpBps;
        maxDispersionBps = cfg.maxDispersionBps;
        minLiveSources = cfg.minLiveSources;
        maxSilence = cfg.maxSilence;
        requireMerkleProof = cfg.requireMerkleProof;
    }

    // -------------------------------------------------------------------------
    // Fact-layer hooks — the only thing an arm implements
    // -------------------------------------------------------------------------

    function _current(uint8 sourceId, uint256 tokenId, Ctx memory ctx) internal view virtual returns (PriceFact memory);

    function _previous(uint8 sourceId, uint256 tokenId, Ctx memory ctx) internal view virtual returns (PriceFact memory);

    function _asOf(uint8 sourceId, uint256 tokenId, uint64 targetTs, Ctx memory ctx)
        internal
        view
        virtual
        returns (bool found, uint128 priceUsdc6, uint256 hops);

    /// @notice One read for both writer-liveness answers, so no arm pays for the same lookup twice.
    /// @return fresh Whether the writer has heartbeat within `maxSilence`.
    /// @return root The Merkle root over the token ids the writer's latest cycle covered.
    function _writerLiveness(uint8 sourceId, Ctx memory ctx) internal view virtual returns (bool fresh, bytes32 root);

    function _isLocked(uint8 sourceId, uint256 tokenId, Ctx memory ctx) internal view virtual returns (bool);

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
        Ctx memory ctx = _decodeContext(oracleContext);
        uint256 total;
        uint256 count;
        for (uint256 i; i < tokenIds.length; ++i) {
            if (tokenIdQuantities[i] == 0) revert ZeroQuantity(i);
            ctx.tokenIndex = i;
            (bool pass, bytes32 checkId, uint256 usable,) = _evaluate(currencyToken, tokenIds[i], ctx);
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
        return _evaluate(currencyToken, tokenId, _decodeContext(oracleContext));
    }

    /// @notice Encode the context bytes a pool would forward, for one token.
    function encodeContext(bytes32[3] memory priceUids, bytes32[3] memory heartbeatUids, bytes32[][] memory proofs)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(priceUids, heartbeatUids, proofs);
    }

    // -------------------------------------------------------------------------
    // Internals — identical across arms
    // -------------------------------------------------------------------------

    function _decodeContext(bytes calldata oracleContext) internal pure returns (Ctx memory ctx) {
        if (oracleContext.length == 0) return ctx;
        (ctx.priceUids, ctx.heartbeatUids, ctx.proofs) =
            abi.decode(oracleContext, (bytes32[3], bytes32[3], bytes32[][]));
    }

    function _evaluate(address currencyToken, uint256 tokenId, Ctx memory ctx)
        internal
        view
        returns (bool pass, bytes32 failedCheck, uint256 usable, uint256 walkHops)
    {
        if (currencyToken != usdc) return (false, CHECK_CURRENCY, 0, 0);
        (uint256 liveCount, uint128 currentMin, uint128 currentMax, bool anyFresh) = _collectLiveMinMax(tokenId, ctx);
        if (!anyFresh) return (false, CHECK_HEARTBEAT, 0, 0);
        if (liveCount < uint256(minLiveSources) || currentMin == 0) return (false, CHECK_MIN_SOURCES, 0, 0);
        uint256 ratioBps = (uint256(currentMax) * uint256(BPS_DENOMINATOR)) / uint256(currentMin);
        if (ratioBps > uint256(maxDispersionBps)) return (false, CHECK_DISPERSION, 0, 0);
        (uint128 usablePrice, uint256 hops) = _applyTemporalFloor(tokenId, currentMin, ctx);
        return (true, bytes32(0), uint256(usablePrice), hops);
    }

    /// @notice Whether this oracle source counts as live for this token, and its price if so.
    function _liveFact(uint8 sourceId, uint256 tokenId, Ctx memory ctx)
        internal
        view
        returns (bool live, bool fresh, PriceFact memory fact)
    {
        bytes32 root;
        (fresh, root) = _writerLiveness(sourceId, ctx);
        if (!fresh) return (false, false, fact);
        if (_isLocked(sourceId, tokenId, ctx)) return (false, true, fact);
        if (requireMerkleProof && !_provenUnderRoot(sourceId, tokenId, ctx, root)) return (false, true, fact);
        fact = _current(sourceId, tokenId, ctx);
        if (!fact.present || fact.priceUsdc6 == 0) return (false, true, fact);
        if (_trippedBreaker(sourceId, tokenId, fact, ctx)) return (false, true, fact);
        return (true, true, fact);
    }

    function _collectLiveMinMax(uint256 tokenId, Ctx memory ctx)
        internal
        view
        returns (uint256 liveCount, uint128 currentMin, uint128 currentMax, bool anyFresh)
    {
        currentMin = type(uint128).max;
        for (uint8 sid; sid < SOURCE_COUNT; ++sid) {
            (bool live, bool fresh, PriceFact memory f) = _liveFact(sid, tokenId, ctx);
            if (fresh) anyFresh = true;
            if (!live) continue;
            if (f.priceUsdc6 < currentMin) currentMin = f.priceUsdc6;
            if (f.priceUsdc6 > currentMax) currentMax = f.priceUsdc6;
            unchecked {
                ++liveCount;
            }
        }
        if (liveCount == 0) {
            currentMin = 0;
            currentMax = 0;
        }
    }

    function _applyTemporalFloor(uint256 tokenId, uint128 currentMin, Ctx memory ctx)
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
            (bool live,,) = _liveFact(sid, tokenId, ctx);
            if (!live) continue;
            (bool found, uint128 p, uint256 hops) = _asOf(sid, tokenId, targetTs, ctx);
            walkHops += hops;
            if (!found) continue;
            if (p < pastMin) pastMin = p;
            any = true;
        }
        if (any && pastMin < usablePrice) usablePrice = pastMin;
    }

    /// @notice Merkle membership of the token under the writer's cycle root.
    /// @dev Leaf is `keccak256(abi.encode(tokenId))`, sorted-pair hashing, per Tim's rule.
    function _provenUnderRoot(uint8 sourceId, uint256 tokenId, Ctx memory ctx, bytes32 root)
        internal
        pure
        returns (bool)
    {
        if (root == bytes32(0)) return false;
        uint256 idx = ctx.tokenIndex * uint256(SOURCE_COUNT) + uint256(sourceId);
        if (idx >= ctx.proofs.length) return false;
        bytes32[] memory proof = ctx.proofs[idx];
        bytes32 computed = keccak256(abi.encode(tokenId));
        for (uint256 i; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            computed = computed <= sibling
                ? keccak256(abi.encode(computed, sibling))
                : keccak256(abi.encode(sibling, computed));
        }
        return computed == root;
    }

    /// @notice Rate-of-change breaker.
    function _trippedBreaker(uint8 sourceId, uint256 tokenId, PriceFact memory current, Ctx memory ctx)
        internal
        view
        returns (bool)
    {
        if (maxJumpBps == 0) return false;
        PriceFact memory prev = _previous(sourceId, tokenId, ctx);
        if (!prev.present || prev.priceUsdc6 == 0) return false;
        uint256 cur = uint256(current.priceUsdc6);
        uint256 prv = uint256(prev.priceUsdc6);
        uint256 hi = cur > prv ? cur : prv;
        uint256 lo = cur > prv ? prv : cur;
        return ((hi - lo) * uint256(BPS_DENOMINATOR)) / prv > uint256(maxJumpBps);
    }
}
