// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EasArmBase} from "./EasArmBase.sol";

/// @notice ENG-3922 Option C — a read-path variant of arm 1: the uid arrives from the caller.
/// @dev Tim's question of 3 September 16:33Z. Nothing of ours is deployed at all: the head uid
///      comes in through the `oracleContext` bytes MetaStreet's pool already forwards to
///      `price()`, and every safety property rests on validating it. `EasArmBase._readPrice`
///      does that validation: schema, attester in the immutable trusted set, the token id and
///      oracle source decoded from `data` matching the token being priced, `revocationTime`
///      zero, `expirationTime` unpassed. Freshness is the seasoning and heartbeat checks above.
///
///      The hazard, stated plainly because the measurement does not capture it: `oracleContext`
///      is caller-supplied and MetaStreet's `ExternalPriceOracle` passes it through unvalidated,
///      so a borrower chooses WHICH valid attestation is read. Validation bounds that to
///      "some attestation this writer really made about this token that is not revoked or
///      expired" — it cannot force "the latest one". The writer's discipline of revoking the
///      superseded attestation in the same transaction as its replacement is what closes the
///      gap, and a writer that attests without revoking leaves two valid attestations and the
///      borrower picks the higher. That is a live-operations risk, not a gas number.
///
///      The uids ride in the same `oracleContext` struct every arm now decodes, alongside the
///      Merkle proofs Tim's 18:17Z rule requires. An empty context reads as "no uid supplied".
contract ArmEasContext is EasArmBase {
    constructor(AggConfig memory cfg, EasConfig memory easCfg) EasArmBase(cfg, easCfg) {}

    function _headUid(uint8 sourceId, uint256, Ctx memory ctx) internal pure override returns (bytes32) {
        return ctx.priceUids[sourceId];
    }

    function _cycleCloseUid(uint8 sourceId, Ctx memory ctx) internal pure override returns (bytes32) {
        return ctx.cycleCloseUids[sourceId];
    }
}
