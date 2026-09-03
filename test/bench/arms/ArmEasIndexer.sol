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
    IEASIndexer public immutable indexer;

    constructor(AggConfig memory cfg, EasConfig memory easCfg, address indexer_) EasArmBase(cfg, easCfg) {
        if (indexer_ == address(0)) revert InvalidConfig();
        indexer = IEASIndexer(indexer_);
    }

    /// @notice The address a token is addressed by, given EAS's address-shaped `recipient`.
    function recipientForToken(uint256 tokenId) public pure returns (address) {
        return address(uint160(tokenId));
    }

    function _headUid(uint8 sourceId, uint256 tokenId, Ctx memory) internal view override returns (bytes32) {
        bytes32[] memory uids = indexer.getSchemaAttesterRecipientAttestationUIDs(
            priceSchema, writerOf(sourceId), recipientForToken(tokenId), 0, 1, true
        );
        if (uids.length == 0) return bytes32(0);
        return uids[0];
    }

    function _cycleCloseUid(uint8 sourceId, Ctx memory) internal view override returns (bytes32) {
        bytes32[] memory uids = indexer.getSchemaAttesterRecipientAttestationUIDs(
            cycleCloseSchema, writerOf(sourceId), writerOf(sourceId), 0, 1, true
        );
        if (uids.length == 0) return bytes32(0);
        return uids[0];
    }
}
