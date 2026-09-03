// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal EAS v0.26 surface, transcribed from the VERIFIED deployed ABI.
/// @dev Sepolia EAS 0xC2679fBD37d54388Ce493F1DB75320D236e1815e, SchemaRegistry
///      0x0a7E2Ff54e76B8E6659aedc9103FB21c038050D0, both `VERSION()` = "0.26", and the EAS's
///      own `getSchemaRegistry()` returns that registry address. Neither exposes `owner()`.
///      Field order below is the deployed ABI's, not the documentation's.

struct Attestation {
    bytes32 uid;
    bytes32 schema;
    uint64 time;
    uint64 expirationTime;
    uint64 revocationTime;
    bytes32 refUID;
    address recipient;
    address attester;
    bool revocable;
    bytes data;
}

struct AttestationRequestData {
    address recipient;
    uint64 expirationTime;
    bool revocable;
    bytes32 refUID;
    bytes data;
    uint256 value;
}

struct AttestationRequest {
    bytes32 schema;
    AttestationRequestData data;
}

struct MultiAttestationRequest {
    bytes32 schema;
    AttestationRequestData[] data;
}

struct RevocationRequestData {
    bytes32 uid;
    uint256 value;
}

struct RevocationRequest {
    bytes32 schema;
    RevocationRequestData data;
}

struct MultiRevocationRequest {
    bytes32 schema;
    RevocationRequestData[] data;
}

interface IEAS {
    function attest(AttestationRequest calldata request) external payable returns (bytes32);

    function multiAttest(MultiAttestationRequest[] calldata multiRequests) external payable returns (bytes32[] memory);

    function revoke(RevocationRequest calldata request) external payable;

    function multiRevoke(MultiRevocationRequest[] calldata multiRequests) external payable;

    function getAttestation(bytes32 uid) external view returns (Attestation memory);

    function isAttestationValid(bytes32 uid) external view returns (bool);

    function getSchemaRegistry() external view returns (address);
}

interface ISchemaRegistry {
    function register(string calldata schema, address resolver, bool revocable) external returns (bytes32);
}

/// @notice EAS `Indexer`, deployed on Sepolia only (there is no `Indexer.json` in the EAS repo's
///         `deployments/mainnet/`). Indexing is NOT automatic: `indexAttestation` is a separate
///         write per attestation, which is a cost the all-EAS arm must carry.
interface IEASIndexer {
    function indexAttestation(bytes32 uid) external;

    function indexAttestations(bytes32[] calldata uids) external;

    function isAttestationIndexed(bytes32 uid) external view returns (bool);

    function getSchemaAttesterRecipientAttestationUIDs(
        bytes32 schema,
        address attester,
        address recipient,
        uint256 start,
        uint256 length,
        bool reverseOrder
    ) external view returns (bytes32[] memory);

    function getSchemaAttesterRecipientAttestationUIDCount(bytes32 schema, address attester, address recipient)
        external
        view
        returns (uint256);
}
