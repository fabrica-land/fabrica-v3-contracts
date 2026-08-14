// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ZoneParameters, SpentItem, ReceivedItem, ItemType} from "../lib/seaport-types/src/lib/ConsiderationStructs.sol";

/// @notice Shared construction of the two things every FabricaMarketplaceZone test needs: the
/// packed `extraData` blob and a `ZoneParameters` carrying it.
/// @dev Single source of truth for the extraData byte layout. It has to match
/// `FabricaMarketplaceZone._verify`'s assembly decode exactly, so it is worth having in one place
/// rather than re-derived per test file — the unit suite and the Sepolia attestation had
/// independent copies of this formula before this library existed.
library ZoneAuthorizationFixture {
    /// @dev Layout: expiry(8) | defUrlLen(2) | defUrl(N) | dpId(36) | signature.
    function buildExtraData(
        uint64 expiry,
        string memory definitionUrl,
        string memory disclosurePackageId,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        bytes memory definitionUrlBytes = bytes(definitionUrl);
        return abi.encodePacked(
            expiry, uint16(definitionUrlBytes.length), definitionUrlBytes, bytes(disclosurePackageId), signature
        );
    }

    /// @dev An offer-side ERC-1155 listing, which is the shape `_verifyDefinitionUrl` resolves
    /// through its offer loop. `startTime`/`endTime` are explicit because the unit suite wants
    /// live timestamps while the fork attestation pins zeroes.
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
        bytes32[] memory orderHashes = new bytes32[](1);
        orderHashes[0] = orderHash;
        return ZoneParameters({
            orderHash: orderHash,
            fulfiller: address(0),
            offerer: address(0),
            offer: offer,
            consideration: new ReceivedItem[](0),
            extraData: extraData,
            orderHashes: orderHashes,
            startTime: startTime,
            endTime: endTime,
            zoneHash: bytes32(0)
        });
    }
}
