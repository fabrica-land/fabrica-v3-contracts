// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IFabricaAttributeOracle} from "./interfaces/IFabricaAttributeOracle.sol";

/// @notice Renounced (post-config) on-chain aggregator: MIN + temporal floor + eligibility.
/// @dev Pool's IPriceOracle entrypoint (ENG-3519 WP-A). Reads FabricaAttributeOracle facts only.
///      "Fabrica relays facts; the renounced aggregator holds the rules."
///      Patch path: deploy NEW aggregator + timelocked setPriceOracle repoint — never upgrade.
///      Check-set is immutable after renounce; new checks = new aggregator deploy.
contract FabricaOracleAggregator is Ownable2Step, IPriceOracle {
    // -------------------------------------------------------------------------
    // Constants / check IDs (per-check observability)
    // -------------------------------------------------------------------------

    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Check id: currency is not the configured USDC.
    bytes32 public constant CHECK_CURRENCY = keccak256("currency");
    /// @notice Check id: keeper dead-man silence.
    bytes32 public constant CHECK_HEARTBEAT = keccak256("heartbeat");
    /// @notice Check id: token not registered / not seasoned.
    bytes32 public constant CHECK_REGISTRY = keccak256("registry");
    /// @notice Check id: recovery status not Normal.
    bytes32 public constant CHECK_RECOVERY = keccak256("recovery");
    /// @notice Check id: fewer than minLiveSources after filters.
    bytes32 public constant CHECK_MIN_SOURCES = keccak256("min_sources");
    /// @notice Check id: dispersion (max/min) exceeded.
    bytes32 public constant CHECK_DISPERSION = keccak256("dispersion");
    /// @notice Check id: land-use attribute required and missing/wrong.
    bytes32 public constant CHECK_LAND_USE = keccak256("land_use");
    /// @notice Attribute id for optional land-use fact (keccak256("landUse") off-chain convention).
    bytes32 public constant ATTR_LAND_USE = keccak256("landUse");

    // -------------------------------------------------------------------------
    // Config (immutable after renounce — setters onlyOwner)
    // -------------------------------------------------------------------------

    /// @notice Fact store (ENG-3518).
    IFabricaAttributeOracle public factStore;
    /// @notice Only accepted currency (USDC).
    address public usdc;
    /// @notice Validator id under which feeds are published.
    uint256 public validatorId;
    /// @notice Source ids considered (v1: 0=Prycd, 1=OpenAVM, 2=Regrid).
    uint8[] private _sourceIds;
    /// @notice Asymmetric seasoning window N (seconds). Increases wait; decreases immediate.
    uint64 public seasoningWindow;
    /// @notice Max inter-publication jump in bps before a feed is dropped (rate-of-change breaker).
    uint16 public maxJumpBps;
    /// @notice Max allowed maxPrice/minPrice among live feeds in bps of min (e.g. 20000 = 2×).
    uint16 public maxDispersionBps;
    /// @notice Minimum independent live sources after breaker (≥2).
    uint8 public minLiveSources;
    /// @notice When true, land-use attribute must equal `requiredLandUse`.
    bool public requireLandUse;
    /// @notice Required land-use attribute value when `requireLandUse` is set.
    bytes32 public requiredLandUse;
    /// @notice True after renounce — all setters permanently disabled.
    bool public renounced;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidConfig();
    error AlreadyRenounced();
    error NotRenounceable();
    error InvalidLength();
    error ZeroQuantity(uint256 index);
    error CheckFailed(bytes32 checkId);
    error NoLiveSources();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event FactStoreSet(address indexed factStore);
    event UsdcSet(address indexed usdc);
    event ValidatorIdSet(uint256 validatorId);
    event SourceIdsSet(uint8[] sourceIds);
    event KnobsSet(uint64 seasoningWindow, uint16 maxJumpBps, uint16 maxDispersionBps, uint8 minLiveSources);
    event LandUsePolicySet(bool requireLandUse, bytes32 requiredLandUse);
    event AggregatorRenounced(address indexed previousOwner);

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    /// @notice Deploy aggregator with owner and initial wiring. Renounce after knobs are set.
    constructor(
        address owner_,
        address factStore_,
        address usdc_,
        uint256 validatorId_,
        uint8[] memory sourceIds_,
        uint64 seasoningWindow_,
        uint16 maxJumpBps_,
        uint16 maxDispersionBps_,
        uint8 minLiveSources_
    ) Ownable(owner_) {
        if (owner_ == address(0) || factStore_ == address(0) || usdc_ == address(0)) {
            revert ZeroAddress();
        }
        _setSourceIds(sourceIds_);
        _setKnobs(seasoningWindow_, maxJumpBps_, maxDispersionBps_, minLiveSources_);
        factStore = IFabricaAttributeOracle(factStore_);
        usdc = usdc_;
        validatorId = validatorId_;
        emit FactStoreSet(factStore_);
        emit UsdcSet(usdc_);
        emit ValidatorIdSet(validatorId_);
    }

    /// @notice Phase-0 / plan start proposals for design-review table (not auto-applied).
    /// @dev Design-review knobs (Tim/Fede pre-deploy): seasoningWindow=24h, maxJumpBps=TBD,
    ///      maxDispersionBps=TBD, minLiveSources=2, check-set immutable post-renounce,
    ///      new checks = new aggregator deploy + setPriceOracle repoint only.
    ///      Temporal order: MIN-then-temporal (v1 default; temporal-then-MIN is open alt).
    function designReviewDefaults()
        external
        pure
        returns (
            uint64 seasoningWindow_,
            uint16 maxJumpBps_,
            uint16 maxDispersionBps_,
            uint8 minLiveSources_,
            string memory temporalOrder_,
            string memory checkSetEvolution_
        )
    {
        return (
            24 hours,
            5000, // 50% jump start proposal — design review before real deploy
            20_000, // max/min ≤ 2.0× start proposal
            2,
            "MIN-then-temporal",
            "immutable-post-renounce; new-checks=new-aggregator-deploy"
        );
    }

    // -------------------------------------------------------------------------
    // Admin (pre-renounce only)
    // -------------------------------------------------------------------------

    function setFactStore(address factStore_) external onlyOwner {
        _requireNotRenounced();
        if (factStore_ == address(0)) revert ZeroAddress();
        factStore = IFabricaAttributeOracle(factStore_);
        emit FactStoreSet(factStore_);
    }

    function setUsdc(address usdc_) external onlyOwner {
        _requireNotRenounced();
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = usdc_;
        emit UsdcSet(usdc_);
    }

    function setValidatorId(uint256 validatorId_) external onlyOwner {
        _requireNotRenounced();
        validatorId = validatorId_;
        emit ValidatorIdSet(validatorId_);
    }

    function setSourceIds(uint8[] calldata sourceIds_) external onlyOwner {
        _requireNotRenounced();
        _setSourceIds(sourceIds_);
    }

    function setKnobs(uint64 seasoningWindow_, uint16 maxJumpBps_, uint16 maxDispersionBps_, uint8 minLiveSources_)
        external
        onlyOwner
    {
        _requireNotRenounced();
        _setKnobs(seasoningWindow_, maxJumpBps_, maxDispersionBps_, minLiveSources_);
    }

    function setLandUsePolicy(bool requireLandUse_, bytes32 requiredLandUse_) external onlyOwner {
        _requireNotRenounced();
        requireLandUse = requireLandUse_;
        requiredLandUse = requiredLandUse_;
        emit LandUsePolicySet(requireLandUse_, requiredLandUse_);
    }

    /// @notice Permanently freeze config. Only evolution path: new deploy + pool repoint.
    function renounceAggregator() external onlyOwner {
        _requireNotRenounced();
        renounced = true;
        address prev = owner();
        _transferOwnership(address(0));
        emit AggregatorRenounced(prev);
    }

    /// @notice Disabled — use `renounceAggregator` which also freezes knobs.
    function renounceOwnership() public pure override {
        revert NotRenounceable();
    }

    function sourceIds() external view returns (uint8[] memory) {
        return _sourceIds;
    }

    // -------------------------------------------------------------------------
    // IPriceOracle
    // -------------------------------------------------------------------------

    /// @inheritdoc IPriceOracle
    /// @dev oracleContext unused (empty for launch path). USDC 1e6 per unit supply.
    ///      Evaluation order (MIN-then-temporal): currency → heartbeat → registry → recovery →
    ///      live sources + breaker → MIN → temporal floor → dispersion → land-use → return.
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
            uint256 unit = _unitPrice(currencyToken, tokenIds[i]);
            total += unit * tokenIdQuantities[i];
            count += tokenIdQuantities[i];
        }
        return total / count;
    }

    // -------------------------------------------------------------------------
    // Observability
    // -------------------------------------------------------------------------

    /// @notice Explain eligibility for a single token (per-check visibility).
    /// @return ok True if `price` would succeed for qty 1 of this token (USDC).
    /// @return failedCheck First failed check id, or bytes32(0) if ok.
    function eligibilityReport(address currencyToken, uint256 tokenId)
        external
        view
        returns (bool ok, bytes32 failedCheck)
    {
        (bool pass, bytes32 checkId,) = _evaluate(currencyToken, tokenId);
        return (pass, checkId);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _unitPrice(address currencyToken, uint256 tokenId) internal view returns (uint256) {
        (bool pass, bytes32 checkId, uint256 usable) = _evaluate(currencyToken, tokenId);
        if (!pass) revert CheckFailed(checkId);
        return usable;
    }

    function _evaluate(address currencyToken, uint256 tokenId)
        internal
        view
        returns (bool pass, bytes32 failedCheck, uint256 usable)
    {
        if (currencyToken != usdc) {
            return (false, CHECK_CURRENCY, 0);
        }
        bytes32 gateFail = _gateChecks(tokenId);
        if (gateFail != bytes32(0)) {
            return (false, gateFail, 0);
        }
        (uint8 liveCount, uint128 currentMin, uint128 currentMax) = _collectLiveMinMax(tokenId);
        if (liveCount < minLiveSources || currentMin == 0) {
            return (false, CHECK_MIN_SOURCES, 0);
        }
        uint256 ratioBps = (uint256(currentMax) * uint256(BPS_DENOMINATOR)) / uint256(currentMin);
        if (ratioBps > uint256(maxDispersionBps)) {
            return (false, CHECK_DISPERSION, 0);
        }
        uint128 usablePrice = _applyTemporalFloor(tokenId, currentMin);
        if (!_landUseOk(tokenId)) {
            return (false, CHECK_LAND_USE, 0);
        }
        return (true, bytes32(0), uint256(usablePrice));
    }

    function _gateChecks(uint256 tokenId) internal view returns (bytes32 failedCheck) {
        IFabricaAttributeOracle store = factStore;
        uint256 vid = validatorId;
        if (!store.isHeartbeatFresh(vid)) return CHECK_HEARTBEAT;
        if (!store.isRegistrySeasoned(vid, tokenId)) return CHECK_REGISTRY;
        if (!store.isRecoveryNormal(vid, tokenId)) return CHECK_RECOVERY;
        return bytes32(0);
    }

    function _collectLiveMinMax(uint256 tokenId)
        internal
        view
        returns (uint8 liveCount, uint128 currentMin, uint128 currentMax)
    {
        IFabricaAttributeOracle store = factStore;
        uint256 vid = validatorId;
        uint256 n = _sourceIds.length;
        currentMin = type(uint128).max;
        currentMax = 0;
        for (uint256 i; i < n; ++i) {
            uint8 sid = _sourceIds[i];
            if (!store.sourceEnabled(sid)) continue;
            IFabricaAttributeOracle.SourcePrice memory sp = store.getSourcePrice(vid, tokenId, sid);
            if (sp.priceUsdc6 == 0) continue;
            if (!store.isCycleValid(vid, sp.cycle)) continue;
            if (_trippedBreaker(store, vid, tokenId, sid, sp)) continue;
            if (sp.priceUsdc6 < currentMin) currentMin = sp.priceUsdc6;
            if (sp.priceUsdc6 > currentMax) currentMax = sp.priceUsdc6;
            unchecked {
                ++liveCount;
            }
        }
        if (liveCount == 0) {
            currentMin = 0;
            currentMax = 0;
        }
    }

    function _applyTemporalFloor(uint256 tokenId, uint128 currentMin) internal view returns (uint128 usablePrice) {
        usablePrice = currentMin;
        if (seasoningWindow == 0) return usablePrice;
        uint64 targetTs = uint64(block.timestamp) > seasoningWindow ? uint64(block.timestamp) - seasoningWindow : 0;
        (bool anyPast, uint128 pastMin) = _pastMinOfLive(factStore, validatorId, tokenId, targetTs);
        if (anyPast && pastMin < usablePrice) {
            usablePrice = pastMin;
        }
    }

    function _landUseOk(uint256 tokenId) internal view returns (bool) {
        if (!requireLandUse) return true;
        IFabricaAttributeOracle.AttributeFact memory attr = factStore.getAttribute(validatorId, tokenId, ATTR_LAND_USE);
        if (attr.cycle == 0 || attr.value != requiredLandUse) return false;
        return factStore.isCycleValid(validatorId, attr.cycle);
    }

    /// @notice Rate-of-change breaker: drop feed if jump from prior history exceeds maxJumpBps.
    function _trippedBreaker(
        IFabricaAttributeOracle store,
        uint256 vid,
        uint256 tokenId,
        uint8 sid,
        IFabricaAttributeOracle.SourcePrice memory current
    ) internal view returns (bool) {
        if (maxJumpBps == 0) return false;
        uint256 len = store.historyLength(vid, tokenId, sid);
        if (len == 0) return false; // first price: no prior — store MAX_FIRST_PRICE is the defense
        IFabricaAttributeOracle.HistoryEntry memory prev = store.getHistory(vid, tokenId, sid, 0);
        if (prev.priceUsdc6 == 0) return false;
        uint256 cur = uint256(current.priceUsdc6);
        uint256 prv = uint256(prev.priceUsdc6);
        uint256 hi = cur > prv ? cur : prv;
        uint256 lo = cur > prv ? prv : cur;
        // jump bps relative to previous publication
        uint256 jumpBps = ((hi - lo) * uint256(BPS_DENOMINATOR)) / prv;
        return jumpBps > uint256(maxJumpBps);
    }

    /// @notice MIN-then-temporal helper: MIN of each live source's price as-of targetTs.
    function _pastMinOfLive(IFabricaAttributeOracle store, uint256 vid, uint256 tokenId, uint64 targetTs)
        internal
        view
        returns (bool any, uint128 pastMin)
    {
        uint256 n = _sourceIds.length;
        pastMin = type(uint128).max;
        for (uint256 i; i < n; ++i) {
            uint8 sid = _sourceIds[i];
            if (!store.sourceEnabled(sid)) continue;
            IFabricaAttributeOracle.SourcePrice memory sp = store.getSourcePrice(vid, tokenId, sid);
            if (sp.priceUsdc6 == 0 || !store.isCycleValid(vid, sp.cycle)) continue;
            if (_trippedBreaker(store, vid, tokenId, sid, sp)) continue;
            (bool found, uint128 p) = _priceAsOf(store, vid, tokenId, sid, sp, targetTs);
            if (!found) continue;
            if (p < pastMin) pastMin = p;
            any = true;
        }
        if (!any) pastMin = 0;
    }

    /// @notice Price of a source as-of targetTs from current + history (newest-first history).
    function _priceAsOf(
        IFabricaAttributeOracle store,
        uint256 vid,
        uint256 tokenId,
        uint8 sid,
        IFabricaAttributeOracle.SourcePrice memory current,
        uint64 targetTs
    ) internal view returns (bool found, uint128 priceUsdc6) {
        // If current was already written at or before target, it is the as-of value.
        if (current.valuedAt <= targetTs) {
            return (true, current.priceUsdc6);
        }
        // Walk history newest-first for first entry with valuedAt <= targetTs.
        uint256 len = store.historyLength(vid, tokenId, sid);
        for (uint256 i; i < len; ++i) {
            IFabricaAttributeOracle.HistoryEntry memory h = store.getHistory(vid, tokenId, sid, i);
            if (h.valuedAt <= targetTs && h.priceUsdc6 != 0) {
                return (true, h.priceUsdc6);
            }
        }
        return (false, 0);
    }

    function _setSourceIds(uint8[] memory sourceIds_) internal {
        if (sourceIds_.length == 0) revert InvalidConfig();
        delete _sourceIds;
        for (uint256 i; i < sourceIds_.length; ++i) {
            _sourceIds.push(sourceIds_[i]);
        }
        emit SourceIdsSet(sourceIds_);
    }

    function _setKnobs(uint64 seasoningWindow_, uint16 maxJumpBps_, uint16 maxDispersionBps_, uint8 minLiveSources_)
        internal
    {
        if (minLiveSources_ < 2) revert InvalidConfig();
        if (maxDispersionBps_ < BPS_DENOMINATOR) revert InvalidConfig(); // must allow ≥1.0×
        seasoningWindow = seasoningWindow_;
        maxJumpBps = maxJumpBps_;
        maxDispersionBps = maxDispersionBps_;
        minLiveSources = minLiveSources_;
        emit KnobsSet(seasoningWindow_, maxJumpBps_, maxDispersionBps_, minLiveSources_);
    }

    function _requireNotRenounced() internal view {
        if (renounced) revert AlreadyRenounced();
    }
}
