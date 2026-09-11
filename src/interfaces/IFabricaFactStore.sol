// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Read surface of the round-2 permissionless fact store (ENG-3924, `FabricaFactStore`).
/// @dev Reads only. The round-2 aggregator never writes, so the mutating half of the store
///      (`writeFact`, `writeFacts`, `closeCycle`, `setLock`, `setMinValidCycle`, `declarePolicy`) is deliberately
///      absent: an interface an immutable consumer cannot use is a surface a reviewer has to rule
///      out by hand. Struct layouts are copied verbatim from `src/FabricaFactStore.sol`; the
///      aggregator's constructor pins `KIND_PRICE` against the live store so a mismatched or
///      wrong-shaped store cannot be wired in silently.
///
///      `policyOf` is deliberately NOT here. Per the ENG-3924 handoff, a declared limit binds a
///      write and not a writer — a writer can widen its band, write, and restore the old value in
///      one transaction — so `policyOf` is evidence of intent and never proof about a stored value.
///      The aggregator relies on its own immutable bounds instead.
interface IFabricaFactStore {
    /// @notice One writer's current statement about one token under one kind.
    struct Fact {
        uint128 value;
        uint24 confidence;
        uint64 valuedAt;
        uint64 writtenAt;
        uint64 cycle;
        bytes32 data;
    }

    /// @notice A superseded fact, retained so a consumer can walk back through a seasoning window.
    struct HistoryEntry {
        uint128 value;
        uint64 writtenAt;
        uint64 cycle;
    }

    /// @notice A writer's statement that it has finished a cycle: the cycle number and when.
    struct CycleClose {
        uint64 cycle;
        uint64 closedAt;
    }

    /// @notice The `kind` under which oracle sources publish valuations, in USDC 1e6.
    function KIND_PRICE() external view returns (bytes32);

    /// @notice History ring depth per row.
    function historyDepth() external view returns (uint8);

    /// @notice `writer`'s current fact together with whether it is still to be used.
    /// @dev Folds presence, the writer's lock and the writer's floor into one external call.
    function getLiveFact(address writer, uint256 tokenId, bytes32 kind)
        external
        view
        returns (Fact memory fact, bool live);

    /// @notice Whether a cycle number is at or above `writer`'s own floor.
    function isCycleValid(address writer, uint64 cycle) external view returns (bool);

    /// @notice `writer`'s last cycle close: the cycle number and when it was recorded.
    function lastCycleClose(address writer) external view returns (CycleClose memory);

    /// @notice Superseded facts retained for a row, capped at `historyDepth`.
    function historyLength(address writer, uint256 tokenId, bytes32 kind) external view returns (uint256);

    /// @notice A superseded fact, newest first; index 0 is the value the current fact replaced.
    function getHistory(address writer, uint256 tokenId, bytes32 kind, uint256 index)
        external
        view
        returns (HistoryEntry memory);
}
