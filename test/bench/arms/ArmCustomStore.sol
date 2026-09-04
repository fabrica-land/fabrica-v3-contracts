// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BenchAggregatorBase} from "../BenchAggregatorBase.sol";
import {IFabricaAttributeOracle} from "../../../src/interfaces/IFabricaAttributeOracle.sol";

/// @notice The one getter the aggregator's read interface does not carry.
/// @dev `lastHeartbeatCycle` is a public mapping on the deployed `FabricaAttributeOracle` but is
///      absent from `IFabricaAttributeOracle`, which was written for round 1's check-set. Declared
///      here rather than widening the shipped interface, since this arm is calibration only.
interface IRound1HeartbeatCycle {
    function lastHeartbeatCycle(uint256 validatorId) external view returns (uint64);

    function cycleRoot(uint256 validatorId, uint64 cycle) external view returns (bytes32);
}

/// @notice ENG-3922 calibration arm — the harness reading the DEPLOYED round-1 fact store.
/// @dev Not one of the ticket's three arms. Its job is to make the harness's own overhead
///      visible: this subclass reads exactly what `FabricaOracleAggregator` reads, from exactly
///      the contract it reads, so the gap between this arm and the 199,097-gas reference is the
///      harness tax rather than a property of any fact layer. Every other arm is quoted both
///      raw and net of that gap.
contract ArmCustomStore is BenchAggregatorBase {
    IFabricaAttributeOracle public immutable store;
    uint256 public immutable validatorId;

    constructor(AggConfig memory cfg, address store_, uint256 validatorId_) BenchAggregatorBase(cfg) {
        if (store_ == address(0)) revert InvalidConfig();
        store = IFabricaAttributeOracle(store_);
        validatorId = validatorId_;
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
        return PriceFact({
            present: true, priceUsdc6: sp.priceUsdc6, lastWrittenAt: sp.lastWrittenAt, cycle: sp.cycle, ref: bytes32(0)
        });
    }

    function _previous(uint8 sourceId, uint256 tokenId, PriceFact memory head, Ctx memory)
        internal
        view
        override
        returns (PriceFact memory fact)
    {
        if (!head.present) return fact;
        uint256 len = store.historyLength(validatorId, tokenId, sourceId);
        if (len == 0) return fact;
        IFabricaAttributeOracle.HistoryEntry memory prev = store.getHistory(validatorId, tokenId, sourceId, 0);
        if (prev.priceUsdc6 == 0) return fact;
        if (!store.isCycleValid(validatorId, prev.cycle)) return fact;
        return PriceFact({
            present: true,
            priceUsdc6: prev.priceUsdc6,
            lastWrittenAt: prev.lastWrittenAt,
            cycle: prev.cycle,
            ref: bytes32(0)
        });
    }

    function _asOf(uint8 sourceId, uint256 tokenId, uint64 targetTs, PriceFact memory head, Ctx memory)
        internal
        view
        override
        returns (bool found, uint128 priceUsdc6, uint256 hops)
    {
        if (head.present && head.lastWrittenAt != 0 && head.lastWrittenAt <= targetTs && head.priceUsdc6 != 0) {
            return (true, head.priceUsdc6, 0);
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

    /// @dev Round 1 has no cycle-close record: its `anchorRoot` is owner-only and nothing has
    ///      ever anchored a root on Sepolia. The nearest equivalent it does hold is the
    ///      per-validator heartbeat cycle, which is monotonic, so the calibration arm reads that
    ///      as the closed cycle and pays the same one-lookup cost as every other arm.
    function _writerLiveness(uint8, Ctx memory)
        internal
        view
        override
        returns (bool fresh, uint64 closedCycle, bytes32 root)
    {
        fresh = store.isHeartbeatFresh(validatorId);
        uint64 cycle = IRound1HeartbeatCycle(address(store)).lastHeartbeatCycle(validatorId);
        return (fresh, cycle, IRound1HeartbeatCycle(address(store)).cycleRoot(validatorId, cycle));
    }

    /// @dev Round 1 has no coverage stamp of any kind, so the calibration arm reports none and
    ///      is simply ineligible under `CoverageMode.CoverageStamp`. That is the honest answer:
    ///      the stamp is a round-2 write that the deployed contracts do not have.
    function _coveredThrough(uint8, uint256, Ctx memory) internal pure override returns (uint64) {
        return 0;
    }

    /// @dev Round 1 has no writer lock; the recovery status it does have is retired by round-2
    ///      Part A item 3, so this arm reports unlocked and the lock is exercised on the arms
    ///      that actually implement it.
    function _isLocked(uint8, uint256, Ctx memory) internal pure override returns (bool) {
        return false;
    }
}
