// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ZoneParameters, SpentItem, ReceivedItem, ItemType} from "../lib/seaport-types/src/lib/ConsiderationStructs.sol";

/// @notice Shared construction of the things every FabricaMarketplaceZone test needs: the packed
/// `extraData` blob, a `ZoneParameters` carrying it, and owner recovery from a signature blob.
/// @dev Single source of truth for the extraData byte layout. It has to match
/// `FabricaMarketplaceZone._verify`'s assembly decode exactly, so it lives in one place rather
/// than being re-derived per test file. Because every caller now routes through here, the two
/// fixed-width invariants the layout depends on are asserted here too — a wrong-length
/// disclosurePackageId would otherwise shift the signature boundary and surface as a misleading
/// "Bad oracle sig" (or GS020/GS026 under a Safe) rather than as a packing error.
library ZoneAuthorizationFixture {
    /// @dev Layout: expiry(8) | defUrlLen(2) | defUrl(N) | dpId(36) | signature.
    function buildExtraData(
        uint64 expiry,
        string memory definitionUrl,
        string memory disclosurePackageId,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        bytes memory definitionUrlBytes = bytes(definitionUrl);
        require(definitionUrlBytes.length <= type(uint16).max, "definitionUrl too long for the 2-byte length field");
        // _verify slices a FIXED 36 bytes for the disclosure package id
        require(bytes(disclosurePackageId).length == 36, "disclosurePackageId must be exactly 36 bytes");
        return abi.encodePacked(
            expiry, uint16(definitionUrlBytes.length), definitionUrlBytes, bytes(disclosurePackageId), signature
        );
    }

    /// @dev A seller listing: the ERC-1155 sits in `offer`, which is the branch of
    /// `_verifyDefinitionUrl` that resolves through its offer loop.
    function buildZoneParameters(
        bytes32 orderHash,
        bytes memory extraData,
        address tokenAddress,
        uint256 tokenId,
        uint256 startTime,
        uint256 endTime
    ) internal pure returns (ZoneParameters memory) {
        SpentItem[] memory offer = new SpentItem[](1);
        offer[0] = SpentItem({itemType: ItemType.ERC1155, token: tokenAddress, identifier: tokenId, amount: 1});
        return _zoneParameters(orderHash, extraData, offer, new ReceivedItem[](0), startTime, endTime);
    }

    /// @dev A buyer bid: the ERC-1155 sits in `consideration` instead, which is the second,
    /// otherwise-uncovered branch of `_verifyDefinitionUrl`.
    function buildBidZoneParameters(
        bytes32 orderHash,
        bytes memory extraData,
        address tokenAddress,
        uint256 tokenId,
        uint256 startTime,
        uint256 endTime
    ) internal pure returns (ZoneParameters memory) {
        ReceivedItem[] memory consideration = new ReceivedItem[](1);
        consideration[0] = ReceivedItem({
            itemType: ItemType.ERC1155,
            token: tokenAddress,
            identifier: tokenId,
            amount: 1,
            recipient: payable(address(0))
        });
        return _zoneParameters(orderHash, extraData, new SpentItem[](0), consideration, startTime, endTime);
    }

    /// @dev Recovers the signer of the 65-byte slot at `index`, honouring Safe's eth_sign
    /// encoding (v > 30 means the owner signed the personal-sign-prefixed hash, with v - 4).
    /// Shared so the Safe model and the attestation cannot drift in their offset arithmetic.
    function recoverOwnerAt(bytes memory signature, uint256 index, bytes32 signedHash) internal pure returns (address) {
        uint256 offset = index * 65;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(add(signature, 0x20), offset))
            s := mload(add(add(signature, 0x40), offset))
            v := byte(0, mload(add(add(signature, 0x60), offset)))
        }
        if (v > 30) {
            return ecrecover(MessageHashUtils.toEthSignedMessageHash(signedHash), v - 4, r, s);
        }
        return ecrecover(signedHash, v, r, s);
    }

    function _zoneParameters(
        bytes32 orderHash,
        bytes memory extraData,
        SpentItem[] memory offer,
        ReceivedItem[] memory consideration,
        uint256 startTime,
        uint256 endTime
    ) private pure returns (ZoneParameters memory) {
        bytes32[] memory orderHashes = new bytes32[](1);
        orderHashes[0] = orderHash;
        return ZoneParameters({
            orderHash: orderHash,
            fulfiller: address(0),
            offerer: address(0),
            offer: offer,
            consideration: consideration,
            extraData: extraData,
            orderHashes: orderHashes,
            startTime: startTime,
            endTime: endTime,
            zoneHash: bytes32(0)
        });
    }
}
