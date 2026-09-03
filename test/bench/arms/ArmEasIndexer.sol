// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EasArmBase} from "./EasArmBase.sol";
import {IEASIndexer} from "../eas/IEAS.sol";

/// @notice ENG-3922 arm 1 — all-EAS, nothing of ours, via EAS's own `Indexer`.
/// @dev This is the only "all-EAS" read path that owns no contract: the head uid is discovered
///      through EAS's deployed `Indexer`, newest-first.
///
///      Two properties of this arm are findings in their own right, not implementation detail.
///
///      1. `Indexer` is deployed on Sepolia (`0xaEF4103A04090071165F78D45D83A0C0782c2B2a`) and
///         NOT on Ethereum mainnet — the EAS repo has no `Indexer.json` under
///         `deployments/mainnet/`. Whatever this arm measures on Sepolia, it cannot be shipped
///         to mainnet as-is.
///      2. Indexing is not automatic. `indexAttestation` is a SEPARATE write per attestation,
///         so this arm's per-fact write cost is `attest` PLUS `indexAttestation`.
///
///      The per-token key is the one place EAS core offers nothing: the only structured subject
///      field is `recipient`, an `address`. This arm therefore addresses a token by
///      `address(uint160(tokenId))`. Fabrica token ids are `uint256`, so this TRUNCATES to 160
///      bits and two token ids sharing their low 160 bits would share a row. That is a real
///      soundness caveat, recorded here rather than buried in the numbers.
contract ArmEasIndexer is EasArmBase {
    /// @notice A token id that does not fit EAS's address-shaped `recipient` field.
    error TokenIdTooWideForEasRecipient(uint256 tokenId);

    IEASIndexer public immutable indexer;

    constructor(AggConfig memory cfg, EasConfig memory easCfg, address indexer_) EasArmBase(cfg, easCfg) {
        if (indexer_ == address(0)) revert InvalidConfig();
        indexer = IEASIndexer(indexer_);
    }

    /// @notice Newest uid for a (schema, attester, recipient) row, or zero when the row is empty.
    /// @dev The count query is not optional. `Indexer._sliceUIDs` reverts `InvalidOffset` when
    ///      `start >= attestationsLength`, and `start` is 0, so querying a row with no attestations
    ///      REVERTS rather than returning an empty array. Every measurement in this harness happens
    ///      after publication, so the empty case never arose in the numbers — but an aggregator that
    ///      reverts instead of declining a source is a live-path defect, not a test artefact. This is
    ///      also a third write the all-EAS arm needs and the pointer arm does not.
    function _newest(bytes32 schema, address attester, address recipient) internal view returns (bytes32) {
        if (indexer.getSchemaAttesterRecipientAttestationUIDCount(schema, attester, recipient) == 0) {
            return bytes32(0);
        }
        bytes32[] memory uids =
            indexer.getSchemaAttesterRecipientAttestationUIDs(schema, attester, recipient, 0, 1, true);
        if (uids.length == 0) return bytes32(0);
        return uids[0];
    }

    /// @notice The address a token is addressed by, given EAS's address-shaped `recipient`.
    /// @dev EAS core's only structured subject field is `recipient`, an `address`, so a token id has
    ///      to be squeezed into 160 bits. That is lossless for Fabrica: `FabricaToken` derives an id
    ///      as `uint64 smallId = uint64(keccak256(...))` and returns it widened
    ///      (`FabricaToken.sol:363-365`), so every id is below 2^64 — 96 bits of headroom. Observed
    ///      live ids run 62 to 64 bits.
    ///
    ///      The guard is here anyway, because "our ids happen to fit" is an assumption a future
    ///      token contract can break silently: ids `x` and `x + 2^160` would collide on one row, and
    ///      `_newest` could hand back the other token's attestation. `_readPrice` would reject its
    ///      payload and the valid fact for `x` would simply vanish, with the outcome depending on
    ///      publication order. Failing loudly beats a fact disappearing.
    function recipientForToken(uint256 tokenId) public pure returns (address) {
        if (tokenId > type(uint160).max) revert TokenIdTooWideForEasRecipient(tokenId);
        return address(uint160(tokenId));
    }

    function _headUid(uint8 sourceId, uint256 tokenId, Ctx memory) internal view override returns (bytes32) {
        return _newest(priceSchema, writerOf(sourceId), recipientForToken(tokenId));
    }

    function _coverageUid(uint8 sourceId, uint256 tokenId, Ctx memory) internal view override returns (bytes32) {
        return _newest(coverageSchema, writerOf(sourceId), recipientForToken(tokenId));
    }

    function _cycleCloseUid(uint8 sourceId, Ctx memory) internal view override returns (bytes32) {
        return _newest(cycleCloseSchema, writerOf(sourceId), writerOf(sourceId));
    }
}
