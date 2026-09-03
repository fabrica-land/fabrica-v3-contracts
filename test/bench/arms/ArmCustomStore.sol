// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BenchAggregatorBase} from "../BenchAggregatorBase.sol";
import {IFabricaAttributeOracle} from "../../../src/interfaces/IFabricaAttributeOracle.sol";

/// @notice ENG-3922 calibration arm — the harness reading the DEPLOYED round-1 fact store.
/// @dev Not one of the ticket's three arms. Its job is to make the harness's own overhead
///      visible: this subclass reads exactly what `FabricaOracleAggregator` reads, from exactly
///      the contract it reads, so the gap between this arm and the 199,097-gas reference is the
///      harness tax rather than a property of any fact layer. Every other arm is quoted both
///      raw and net of that gap.
contract ArmCustomStore is BenchAggregatorBase {
    IFabricaAttributeOracle public immutable store;
    uint256 public immutable validatorId;
    /// @notice The cycle root the calibration arm proves against.
    /// @dev The deployed round-1 store exposes `cycleRoot` only through its own ABI, which the
    ///      aggregator's read interface does not carry, and nothing has ever anchored a root on
    ///      Sepolia. Supplying it at deploy keeps the calibration arm paying the same proof cost
    ///      as every other arm without pretending round 1 stores something it does not.
    bytes32 public cycleRootOverride;

    constructor(AggConfig memory cfg, address store_, uint256 validatorId_) BenchAggregatorBase(cfg) {
        if (store_ == address(0)) revert InvalidConfig();
        store = IFabricaAttributeOracle(store_);
        validatorId = validatorId_;
    }

    /// @notice Calibration-only setter for the root the proof check runs against.
    function setCycleRoot(bytes32 root) external {
        cycleRootOverride = root;
    }

    function _current(uint8 sourceId, uint256 tokenId, Ctx memory)
        internal
        view
        override
        returns (PriceFact memory fact)
    {
        if (!store.sourceEnabled(sourceId)) return fact;
        IFabricaAttributeOracle.SourcePrice memory sp = store.getSourcePrice(validatorId, tokenId, sourceId);
        if (sp.priceUsdc6 == 0) return fact;
        if (!store.isCycleValid(validatorId, sp.cycle)) return fact;
        return PriceFact({present: true, priceUsdc6: sp.priceUsdc6, lastWrittenAt: sp.lastWrittenAt, cycle: sp.cycle});
    }

    function _previous(uint8 sourceId, uint256 tokenId, Ctx memory)
        internal
        view
        override
        returns (PriceFact memory fact)
    {
        uint256 len = store.historyLength(validatorId, tokenId, sourceId);
        if (len == 0) return fact;
        IFabricaAttributeOracle.HistoryEntry memory prev = store.getHistory(validatorId, tokenId, sourceId, 0);
        if (prev.priceUsdc6 == 0) return fact;
        if (!store.isCycleValid(validatorId, prev.cycle)) return fact;
        return
            PriceFact({
                present: true, priceUsdc6: prev.priceUsdc6, lastWrittenAt: prev.lastWrittenAt, cycle: prev.cycle
            });
    }

    function _asOf(uint8 sourceId, uint256 tokenId, uint64 targetTs, Ctx memory)
        internal
        view
        override
        returns (bool found, uint128 priceUsdc6, uint256 hops)
    {
        IFabricaAttributeOracle.SourcePrice memory sp = store.getSourcePrice(validatorId, tokenId, sourceId);
        if (sp.lastWrittenAt != 0 && sp.lastWrittenAt <= targetTs && sp.priceUsdc6 != 0) {
            return (true, sp.priceUsdc6, 0);
        }
        uint256 len = store.historyLength(validatorId, tokenId, sourceId);
        for (uint256 i; i < len; ++i) {
            IFabricaAttributeOracle.HistoryEntry memory h = store.getHistory(validatorId, tokenId, sourceId, i);
            unchecked {
                ++hops;
            }
            if (h.priceUsdc6 == 0) continue;
            if (!store.isCycleValid(validatorId, h.cycle)) continue;
            if (h.lastWrittenAt == 0) continue;
            if (h.lastWrittenAt <= targetTs) return (true, h.priceUsdc6, hops);
        }
        return (false, 0, hops);
    }

    /// @dev Round 1 anchors a per-cycle Merkle root via the owner-only `anchorRoot`, and the
    ///      calibration arm reads `cycleRoot` for the writer's last heartbeat cycle. Round 2
    ///      moves that write to the heartbeat itself (proposal item 13).
    function _writerLiveness(uint8, Ctx memory) internal view override returns (bool fresh, bytes32 root) {
        fresh = store.isHeartbeatFresh(validatorId);
        return (fresh, cycleRootOverride);
    }

    /// @dev Round 1 has no writer lock; the recovery status it does have is retired by round-2
    ///      Part A item 3, so this arm reports unlocked and the lock is exercised on the arms
    ///      that actually implement it.
    function _isLocked(uint8, uint256, Ctx memory) internal pure override returns (bool) {
        return false;
    }
}
