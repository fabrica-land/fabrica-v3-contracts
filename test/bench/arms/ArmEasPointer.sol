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
    bytes32 public constant KIND_HEARTBEAT = keccak256("heartbeat");

    FactPointer public immutable pointer;

    constructor(AggConfig memory cfg, EasConfig memory easCfg, address pointer_) EasArmBase(cfg, easCfg) {
        if (pointer_ == address(0)) revert InvalidConfig();
        pointer = FactPointer(pointer_);
    }

    function _headUid(uint8 sourceId, uint256 tokenId, Ctx memory) internal view override returns (bytes32) {
        return pointer.headOf(writerOf(sourceId), tokenId, KIND_PRICE);
    }

    /// @notice The heartbeat row is per writer, so it is keyed at tokenId 0.
    function _heartbeatUid(uint8 sourceId, Ctx memory) internal view override returns (bytes32) {
        return pointer.headOf(writerOf(sourceId), 0, KIND_HEARTBEAT);
    }
}
