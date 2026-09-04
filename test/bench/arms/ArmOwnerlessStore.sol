// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BenchAggregatorBase} from "../BenchAggregatorBase.sol";
import {OwnerlessFactStore} from "../OwnerlessFactStore.sol";

/// @notice ENG-3922 arm 3 — the ownerless custom fact store (adoption survey Option B).
/// @dev Facts are keyed by the writer's own address, so the oracle source IS the writer and no
///      `validatorId` or source id exists. The trusted writer set is fixed at deploy.
contract ArmOwnerlessStore is BenchAggregatorBase {
    OwnerlessFactStore public immutable store;

    address internal immutable _writer0;
    address internal immutable _writer1;
    address internal immutable _writer2;

    constructor(AggConfig memory cfg, address store_, address[3] memory writers_) BenchAggregatorBase(cfg) {
        if (store_ == address(0)) revert InvalidConfig();
        store = OwnerlessFactStore(store_);
        _writer0 = writers_[0];
        _writer1 = writers_[1];
        _writer2 = writers_[2];
    }

    function writerOf(uint8 sourceId) public view returns (address) {
        if (sourceId == 0) return _writer0;
        if (sourceId == 1) return _writer1;
        return _writer2;
    }

    function _current(uint8 sourceId, uint256 tokenId, Ctx memory)
        internal
        view
        override
        returns (PriceFact memory fact)
    {
        address w = writerOf(sourceId);
        OwnerlessFactStore.Fact memory f = store.getFact(w, tokenId);
        if (f.priceUsdc6 == 0) return fact;
        if (!store.isCycleValid(w, f.cycle)) return fact;
        return PriceFact({
            present: true, priceUsdc6: f.priceUsdc6, lastWrittenAt: f.lastWrittenAt, cycle: f.cycle, ref: bytes32(0)
        });
    }

    function _previous(uint8 sourceId, uint256 tokenId, PriceFact memory head, Ctx memory)
        internal
        view
        override
        returns (PriceFact memory fact)
    {
        if (!head.present) return fact;
        address w = writerOf(sourceId);
        if (store.historyLength(w, tokenId) == 0) return fact;
        OwnerlessFactStore.HistoryEntry memory h = store.getHistory(w, tokenId, 0);
        if (h.priceUsdc6 == 0) return fact;
        if (!store.isCycleValid(w, h.cycle)) return fact;
        return PriceFact({
            present: true, priceUsdc6: h.priceUsdc6, lastWrittenAt: h.lastWrittenAt, cycle: h.cycle, ref: bytes32(0)
        });
    }

    function _asOf(uint8 sourceId, uint256 tokenId, uint64 targetTs, PriceFact memory head, Ctx memory)
        internal
        view
        override
        returns (bool found, uint128 priceUsdc6, uint256 hops)
    {
        // The head is already in hand from the liveness pass; do not read the fact again.
        if (head.present && head.lastWrittenAt != 0 && head.lastWrittenAt <= targetTs && head.priceUsdc6 != 0) {
            return (true, head.priceUsdc6, 0);
        }
        address w = writerOf(sourceId);
        uint256 len = store.historyLength(w, tokenId);
        for (uint256 i; i < len; ++i) {
            OwnerlessFactStore.HistoryEntry memory h = store.getHistory(w, tokenId, i);
            unchecked {
                ++hops;
            }
            if (h.priceUsdc6 == 0) continue;
            if (!store.isCycleValid(w, h.cycle)) continue;
            if (h.lastWrittenAt == 0) continue;
            if (h.lastWrittenAt <= targetTs) return (true, h.priceUsdc6, hops);
        }
        return (false, 0, hops);
    }

    /// @dev The cycle-close timestamp and the closed cycle number are two slots on the same
    ///      record, so one hook answers both and the arm pays for one lookup, not two.
    function _writerLiveness(uint8 sourceId, Ctx memory)
        internal
        view
        override
        returns (bool fresh, uint64 closedCycle, bytes32 root)
    {
        address w = writerOf(sourceId);
        uint64 last = store.lastHeartbeatAt(w);
        if (last == 0) return (false, 0, bytes32(0));
        fresh = uint256(last) + uint256(maxSilence) >= block.timestamp;
        return (fresh, store.lastHeartbeatCycle(w), store.lastHeartbeatRoot(w));
    }

    function _coveredThrough(uint8 sourceId, uint256 tokenId, Ctx memory) internal view override returns (uint64) {
        return store.coveredThrough(writerOf(sourceId), tokenId);
    }

    /// @notice The writer lock: the writer's own declaration that its facts must not be used.
    function _isLocked(uint8 sourceId, uint256 tokenId, Ctx memory) internal view override returns (bool) {
        return store.locked(writerOf(sourceId), tokenId);
    }
}
