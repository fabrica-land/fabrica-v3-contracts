// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ENG-3922 arm 2 — the ownerless pointer that closes EAS's keying gap.
/// @dev EAS keys attestations by an opaque content-derived `uid` and its only structured
///      subject field is `recipient`, an address, so there is no on-chain way to ask for
///      "writer X's current price for token Y of kind K". This is the roughly 50-line
///      satellite the adoption survey costs into Option A.
///
///      Zero privileged roles, matching round-2 position 2: no owner, no allowlist, no
///      upgrade path. A writer's row is addressed by `msg.sender` and nothing else, so no
///      writer can reach another writer's row — the keying-gap property ticket bullet 2 asks
///      the experiment to demonstrate rather than assert.
contract FactPointer {
    /// @notice writer => tokenId => kind => head attestation uid.
    mapping(address => mapping(uint256 => mapping(bytes32 => bytes32))) private _head;

    /// @notice Emitted whenever a writer repoints one of its own rows.
    event Pointed(address indexed writer, uint256 indexed tokenId, bytes32 indexed kind, bytes32 uid);

    error LengthMismatch();

    /// @notice Point one of the caller's own rows at `uid`.
    function point(uint256 tokenId, bytes32 kind, bytes32 uid) external {
        _head[msg.sender][tokenId][kind] = uid;
        emit Pointed(msg.sender, tokenId, kind, uid);
    }

    /// @notice Point many of the caller's own rows in one transaction.
    function pointBatch(uint256[] calldata tokenIds, bytes32[] calldata kinds, bytes32[] calldata uids) external {
        uint256 n = tokenIds.length;
        if (n != kinds.length || n != uids.length) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            _head[msg.sender][tokenIds[i]][kinds[i]] = uids[i];
            emit Pointed(msg.sender, tokenIds[i], kinds[i], uids[i]);
        }
    }

    /// @notice Head uid for a (writer, tokenId, kind) row. Zero when never pointed.
    function headOf(address writer, uint256 tokenId, bytes32 kind) external view returns (bytes32) {
        return _head[writer][tokenId][kind];
    }
}
