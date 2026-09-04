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
    /// @notice How the aggregator checks that a valuation's token was covered by its cycle.
    /// @dev Tim is choosing between these; the experiment measures all three so the choice has
    ///      numbers under it. 18:17Z asked for proof-at-read, 18:21Z replaced it with the
    ///      closed-cycle check, and 18:31Z reopened it because a writer may cover a token in a
    ///      cycle WITHOUT rewriting an unchanged valuation — in which case coverage lives only in
    ///      the root and only a proof can show it.
    enum CoverageMode {
        /// @dev No on-chain coverage check at all.
        None,
        /// @dev The valuation's cycle must be one its writer has closed. One extra read.
        ClosedCycle,
        /// @dev The token must be proven under the writer's cycle root, proof supplied by the
        ///      caller through `oracleContext`. Ruled out by Tim at 18:44Z: a BNPL loan's
        ///      calldata is fixed days before execution, and a daily cycle close would stale
        ///      every proof already sitting in a signed quote. Kept measurable, not proposed.
        ProofAtRead,
        /// @dev The writer must have stamped this token as still covered at its current cycle.
        ///      Writer-side state only, nothing supplied by the caller, and a writer can cover a
        ///      token it did not revalue without rewriting the valuation.
        CoverageStamp
    }

    /// @notice Everything the liveness pass produces, grouped so `_evaluate` stays shallow.
    struct LiveSet {
        uint256 liveCount;
        uint128 currentMin;
        uint128 currentMax;
        bytes32 firstReason;
        bool[3] live;
        PriceFact[3] facts;
    }

    /// @notice The aggregator's immutable rule set, grouped so subclasses stay shallow.
    struct AggConfig {
        address usdc;
        uint64 seasoningWindow;
        uint16 maxJumpBps;
        uint16 maxDispersionBps;
        uint8 minLiveSources;
        uint64 maxSilence;
        CoverageMode coverage;
    }

    struct PriceFact {
        bool present;
        uint128 priceUsdc6;
        uint64 lastWrittenAt;
        uint64 cycle;
        /// @notice The fact layer's handle for what comes BEFORE this one, when it has one.
        /// @dev On the EAS arms this is the head attestation's `refUID`, so the breaker and the
        ///      seasoning walk can continue from the head the liveness pass already fetched instead
        ///      of resolving and re-reading it. Zero on the store arms, which reach their history by
        ///      index rather than by chaining.
        bytes32 ref;
    }

    /// @notice Everything a caller may pass through `oracleContext`, decoded once per read.
    /// @dev `priceUids` and `cycleCloseUids` are Option C's caller-supplied attestation uids,
    ///      ignored by every arm with an on-chain lookup. `proofs` is used only in
    ///      `CoverageMode.ProofAtRead`, indexed `[tokenIndex * SOURCE_COUNT + sourceId]` so a
    ///      basket carries one proof per token per oracle source.
    struct Ctx {
        bytes32[3] priceUids;
        bytes32[3] cycleCloseUids;
        bytes32[3] coverageUids;
        bytes32[][] proofs;
        uint256 tokenIndex;
    }

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint8 public constant SOURCE_COUNT = 3;

    bytes32 public constant CHECK_CURRENCY = keccak256("currency");
    bytes32 public constant CHECK_HEARTBEAT = keccak256("heartbeat");
    bytes32 public constant CHECK_LOCK = keccak256("lock");
    bytes32 public constant CHECK_CYCLE = keccak256("cycle");
    bytes32 public constant CHECK_MIN_SOURCES = keccak256("min_sources");
    bytes32 public constant CHECK_DISPERSION = keccak256("dispersion");

    address public immutable usdc;
    uint64 public immutable seasoningWindow;
    uint16 public immutable maxJumpBps;
    uint16 public immutable maxDispersionBps;
    uint8 public immutable minLiveSources;
    uint64 public immutable maxSilence;

    /// @notice Which coverage rule this aggregator enforces.
    /// @dev Tim, 3 September 18:21Z, superseding the read-time proof check of 18:17Z: nothing is
    ///      passed at read time and nothing is computed per quote. The oracle writer computes a
    ///      Merkle root over every token it wrote in the cycle and publishes it in the CYCLE
    ///      CLOSE (his name for the heartbeat). The root is an audit commitment; no proof path is
    ///      verified on chain. All the aggregator checks is that this valuation's cycle has been
    ///      closed by its writer. Switchable so the rule's cost can be reported as its own line.
    CoverageMode public immutable coverage;

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
        coverage = cfg.coverage;
    }

    // -------------------------------------------------------------------------
    // Fact-layer hooks — the only thing an arm implements
    // -------------------------------------------------------------------------

    function _current(uint8 sourceId, uint256 tokenId, Ctx memory ctx) internal view virtual returns (PriceFact memory);

    /// @notice The publication immediately before `head`, for the rate-of-change breaker.
    /// @param head The fact `_current` already returned. An earlier version took no head and
    ///        re-resolved it, which cost the EAS arms a second uid lookup and a second full
    ///        `getAttestation` for a record the caller was already holding.
    function _previous(uint8 sourceId, uint256 tokenId, PriceFact memory head, Ctx memory ctx)
        internal
        view
        virtual
        returns (PriceFact memory);

    /// @notice This oracle source's price as of `targetTs`, continuing from `head`.
    function _asOf(uint8 sourceId, uint256 tokenId, uint64 targetTs, PriceFact memory head, Ctx memory ctx)
        internal
        view
        virtual
        returns (bool found, uint128 priceUsdc6, uint256 hops);

    /// @notice One read for both writer-liveness answers, so no arm pays for the same lookup twice.
    /// @return fresh Whether the writer has closed a cycle within `maxSilence`.
    /// @return closedCycle The highest cycle number this writer has closed. Cycles are monotonic,
    ///         so any cycle at or below this one has been closed.
    /// @return root The Merkle root the writer committed for that close, for `ProofAtRead`.
    function _writerLiveness(uint8 sourceId, Ctx memory ctx)
        internal
        view
        virtual
        returns (bool fresh, uint64 closedCycle, bytes32 root);

    function _isLocked(uint8 sourceId, uint256 tokenId, Ctx memory ctx) internal view virtual returns (bool);

    /// @notice The last cycle in which this writer stamped this token as still covered.
    function _coveredThrough(uint8 sourceId, uint256 tokenId, Ctx memory ctx) internal view virtual returns (uint64);

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

    /// @notice Encode the context bytes a pool would forward. Only Option C needs it.
    /// @dev Must stay in lockstep with `_decodeContext`. An earlier version encoded three members
    ///      while the decoder read four, so the bytes this produced could not be decoded: word 6 was
    ///      the `proofs` offset but was read as `coverageUids[0]`. Nothing measured called it, which
    ///      is exactly why it survived. `test_contextRoundTrips` now pins the two together.
    function encodeContext(
        bytes32[3] memory priceUids,
        bytes32[3] memory cycleCloseUids,
        bytes32[3] memory coverageUids,
        bytes32[][] memory proofs
    ) external pure returns (bytes memory) {
        return abi.encode(priceUids, cycleCloseUids, coverageUids, proofs);
    }

    /// @notice Decode context bytes back to their members, so a round-trip is assertable.
    function decodeContext(bytes calldata oracleContext)
        external
        pure
        returns (
            bytes32[3] memory priceUids,
            bytes32[3] memory cycleCloseUids,
            bytes32[3] memory coverageUids,
            bytes32[][] memory proofs
        )
    {
        Ctx memory ctx = _decodeContext(oracleContext);
        return (ctx.priceUids, ctx.cycleCloseUids, ctx.coverageUids, ctx.proofs);
    }

    // -------------------------------------------------------------------------
    // Internals — identical across arms
    // -------------------------------------------------------------------------

    function _decodeContext(bytes calldata oracleContext) internal pure returns (Ctx memory ctx) {
        if (oracleContext.length == 0) return ctx;
        (ctx.priceUids, ctx.cycleCloseUids, ctx.coverageUids, ctx.proofs) =
            abi.decode(oracleContext, (bytes32[3], bytes32[3], bytes32[3], bytes32[][]));
    }

    function _evaluate(address currencyToken, uint256 tokenId, Ctx memory ctx)
        internal
        view
        returns (bool pass, bytes32 failedCheck, uint256 usable, uint256 walkHops)
    {
        if (currencyToken != usdc) return (false, CHECK_CURRENCY, 0, 0);
        LiveSet memory set = _collectLiveMinMax(tokenId, ctx);
        if (set.liveCount == 0) return (false, set.firstReason, 0, 0);
        if (set.liveCount < uint256(minLiveSources) || set.currentMin == 0) {
            return (false, CHECK_MIN_SOURCES, 0, 0);
        }
        if ((uint256(set.currentMax) * uint256(BPS_DENOMINATOR)) / uint256(set.currentMin) > uint256(maxDispersionBps))
        {
            return (false, CHECK_DISPERSION, 0, 0);
        }
        (uint128 usablePrice, uint256 hops) = _applyTemporalFloor(tokenId, set, ctx);
        return (true, bytes32(0), uint256(usablePrice), hops);
    }

    /// @notice Whether this oracle source counts as live for this token, and its price if so.
    /// @notice Whether this oracle source counts as live for this token, and why not when it does not.
    /// @return live Whether the source contributes a valuation.
    /// @return reason The rule that rejected it, or `bytes32(0)` when it is live. An earlier version
    ///         folded lock and coverage rejections into a bare `live == false`, so `price()` reported
    ///         `CHECK_MIN_SOURCES` for a lock and `CHECK_LOCK`/`CHECK_CYCLE` were dead constants.
    ///         The ticket asks for lock and coverage evidence, so the failing check names the rule.
    /// @return fact The valuation, when there is one.
    function _liveFact(uint8 sourceId, uint256 tokenId, Ctx memory ctx)
        internal
        view
        returns (bool live, bytes32 reason, PriceFact memory fact)
    {
        (bool fresh, uint64 closedCycle, bytes32 root) = _writerLiveness(sourceId, ctx);
        if (!fresh) return (false, CHECK_HEARTBEAT, fact);
        if (_isLocked(sourceId, tokenId, ctx)) return (false, CHECK_LOCK, fact);
        if (coverage == CoverageMode.ProofAtRead && !_provenUnderRoot(sourceId, tokenId, ctx, root)) {
            return (false, CHECK_CYCLE, fact);
        }
        fact = _current(sourceId, tokenId, ctx);
        if (!fact.present || fact.priceUsdc6 == 0) return (false, CHECK_MIN_SOURCES, fact);
        if (coverage == CoverageMode.ClosedCycle && (fact.cycle == 0 || fact.cycle > closedCycle)) {
            return (false, CHECK_CYCLE, fact);
        }
        if (coverage == CoverageMode.CoverageStamp) {
            uint64 covered = _coveredThrough(sourceId, tokenId, ctx);
            if (covered == 0 || covered < closedCycle) return (false, CHECK_CYCLE, fact);
        }
        if (_trippedBreaker(sourceId, tokenId, fact, ctx)) return (false, CHECK_MIN_SOURCES, fact);
        return (true, bytes32(0), fact);
    }

    /// @notice Merkle membership of the token under the writer's cycle root.
    /// @dev Leaf is `keccak256(abi.encode(tokenId))`, sorted-pair hashing.
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

    /// @notice Evaluate every oracle source ONCE, and carry the result out.
    /// @dev The live mask is returned rather than recomputed. An earlier version had the temporal
    ///      floor call `_liveFact` again for every source, so every fact-layer read the breaker and
    ///      the liveness check make — `_writerLiveness`, `_isLocked`, `_current`, `_previous` —
    ///      happened TWICE on every `price()` whenever `seasoningWindow != 0`. That inflated the
    ///      reported read gas on every arm and, because the EAS arms pay far more per fact-layer
    ///      read, it inflated them unequally.
    function _collectLiveMinMax(uint256 tokenId, Ctx memory ctx) internal view returns (LiveSet memory set) {
        set.currentMin = type(uint128).max;
        for (uint8 sid; sid < SOURCE_COUNT; ++sid) {
            (bool isLive, bytes32 reason, PriceFact memory f) = _liveFact(sid, tokenId, ctx);
            if (!isLive) {
                if (set.firstReason == bytes32(0)) set.firstReason = reason;
                continue;
            }
            set.live[sid] = true;
            set.facts[sid] = f;
            if (f.priceUsdc6 < set.currentMin) set.currentMin = f.priceUsdc6;
            if (f.priceUsdc6 > set.currentMax) set.currentMax = f.priceUsdc6;
            unchecked {
                ++set.liveCount;
            }
        }
        if (set.liveCount == 0) {
            set.currentMin = 0;
            set.currentMax = 0;
        }
    }

    /// @notice MIN of each live oracle source's price as of the seasoning cutoff.
    /// @param set What `_collectLiveMinMax` already computed: the live mask so liveness is not
    ///        re-evaluated, and the head facts so no arm re-resolves or re-reads a head.
    function _applyTemporalFloor(uint256 tokenId, LiveSet memory set, Ctx memory ctx)
        internal
        view
        returns (uint128 usablePrice, uint256 walkHops)
    {
        usablePrice = set.currentMin;
        if (seasoningWindow == 0) return (usablePrice, 0);
        uint64 targetTs = uint64(block.timestamp) > seasoningWindow ? uint64(block.timestamp) - seasoningWindow : 0;
        uint128 pastMin = type(uint128).max;
        bool any;
        for (uint8 sid; sid < SOURCE_COUNT; ++sid) {
            if (!set.live[sid]) continue;
            (bool found, uint128 p, uint256 hops) = _asOf(sid, tokenId, targetTs, set.facts[sid], ctx);
            walkHops += hops;
            if (!found) continue;
            if (p < pastMin) pastMin = p;
            any = true;
        }
        if (any && pastMin < usablePrice) usablePrice = pastMin;
    }

    /// @notice Rate-of-change breaker.
    function _trippedBreaker(uint8 sourceId, uint256 tokenId, PriceFact memory current, Ctx memory ctx)
        internal
        view
        returns (bool)
    {
        if (maxJumpBps == 0) return false;
        PriceFact memory prev = _previous(sourceId, tokenId, current, ctx);
        if (!prev.present || prev.priceUsdc6 == 0) return false;
        uint256 cur = uint256(current.priceUsdc6);
        uint256 prv = uint256(prev.priceUsdc6);
        uint256 hi = cur > prv ? cur : prv;
        uint256 lo = cur > prv ? prv : cur;
        return ((hi - lo) * uint256(BPS_DENOMINATOR)) / prv > uint256(maxJumpBps);
    }
}
