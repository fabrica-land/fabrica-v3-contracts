// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EasArmBase} from "./EasArmBase.sol";
import {FactPointer} from "../FactPointer.sol";

/// @notice ENG-3922 arm 2 — EAS plus the ownerless pointer (adoption survey Option A).
/// @dev The head uid comes from a deterministic on-chain (writer, tokenId, kind) lookup, which
///      is what closes EAS's keying gap. The caller supplies nothing, so a borrower cannot
///      choose which attestation is read — the hazard the survey flags against Option C.
contract ArmEasPointer is EasArmBase {
    bytes32 public constant KIND_PRICE = keccak256("price");
    bytes32 public constant KIND_CYCLE_CLOSE = keccak256("cycleClose");

    FactPointer public immutable pointer;

    constructor(AggConfig memory cfg, EasConfig memory easCfg, address pointer_) EasArmBase(cfg, easCfg) {
        if (pointer_ == address(0)) revert InvalidConfig();
        pointer = FactPointer(pointer_);
    }

    function _headUid(uint8 sourceId, uint256 tokenId, Ctx memory) internal view override returns (bytes32) {
        return pointer.headOf(writerOf(sourceId), tokenId, KIND_PRICE);
    }

    /// @notice The coverage stamp is a slot on the pointer, not an attestation.
    /// @dev A stamp attestation would spend a whole EAS record on one integer. This arm already
    ///      ships a contract of its own, so the cheapest honest stamp is a slot on it.
    function _coveredThrough(uint8 sourceId, uint256 tokenId, Ctx memory) internal view override returns (uint64) {
        return pointer.coveredThrough(writerOf(sourceId), tokenId);
    }

    /// @notice The cycle-close row is per writer, so it is keyed at tokenId 0.
    /// @dev Unused on this arm: the stamp is a pointer slot, so no coverage attestation exists.
    function _coverageUid(uint8, uint256, Ctx memory) internal pure override returns (bytes32) {
        return bytes32(0);
    }

    function _cycleCloseUid(uint8 sourceId, Ctx memory) internal view override returns (bytes32) {
        return pointer.headOf(writerOf(sourceId), 0, KIND_CYCLE_CLOSE);
    }
}
