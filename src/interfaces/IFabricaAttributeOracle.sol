// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal view surface of FabricaAttributeOracle for the renounced aggregator (ENG-3519).
/// @dev Matches storage/read model of ENG-3518 Phase-0 lock. Aggregator must apply isCycleValid.
interface IFabricaAttributeOracle {
    struct Provenance {
        bytes32 rawPayloadHash;
        bytes32 inputsHash;
        uint64 timestamp;
        address signer;
    }

    struct SourcePrice {
        uint128 priceUsdc6;
        uint24 confidenceScore;
        uint64 valuedAt;
        uint64 lastWrittenAt;
        uint64 cycle;
        Provenance provenance;
    }

    struct HistoryEntry {
        uint128 priceUsdc6;
        uint64 valuedAt;
        uint64 cycle;
    }

    struct AttributeFact {
        bytes32 value;
        uint64 cycle;
        Provenance provenance;
    }

    function getSourcePrice(uint256 validatorId, uint256 tokenId, uint8 sourceId)
        external
        view
        returns (SourcePrice memory);

    function isRecoveryNormal(uint256 validatorId, uint256 tokenId) external view returns (bool);

    function getAttribute(uint256 validatorId, uint256 tokenId, bytes32 attributeId)
        external
        view
        returns (AttributeFact memory);

    function isRegistrySeasoned(uint256 validatorId, uint256 tokenId) external view returns (bool);

    function isHeartbeatFresh(uint256 validatorId) external view returns (bool);

    function isCycleValid(uint256 validatorId, uint64 cycle) external view returns (bool);

    function historyLength(uint256 validatorId, uint256 tokenId, uint8 sourceId) external view returns (uint256);

    function getHistory(uint256 validatorId, uint256 tokenId, uint8 sourceId, uint256 index)
        external
        view
        returns (HistoryEntry memory);

    function sourceEnabled(uint8 sourceId) external view returns (bool);

    function RECOVERY_NORMAL() external view returns (uint8);
}
