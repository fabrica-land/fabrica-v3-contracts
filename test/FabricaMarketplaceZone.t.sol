// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FabricaMarketplaceZone} from "../src/FabricaMarketplaceZone.sol";
import {ZoneParameters, SpentItem, ReceivedItem, ItemType} from "../lib/seaport-types/src/lib/ConsiderationStructs.sol";

// Mock FabricaToken for testing
contract MockFabricaToken {
    struct Property {
        uint256 supply;
        string operatingAgreement;
        string definition;
        string configuration;
        address validator;
    }

    mapping(uint256 => Property) public _property;

    function setProperty(uint256 tokenId, string memory definition) external {
        _property[tokenId].definition = definition;
    }
}

contract FabricaMarketplaceZoneTest is Test {
    FabricaMarketplaceZone public zone;
    MockFabricaToken public mockToken;

    uint256 internal signerPrivateKey;
    address internal signer;

    bytes32 private constant _EIP712_TYPE_HASH = keccak256(
        "OrderAuthorization(bytes32 orderHash,uint64 expiry,string definitionUrl,string disclosurePackageId)"
    );

    function setUp() public {
        signerPrivateKey = 0xA11CE;
        signer = vm.addr(signerPrivateKey);

        zone = new FabricaMarketplaceZone(signer);
        mockToken = new MockFabricaToken();
    }

    function _buildDomainSeparator(address zoneAddress) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("FabricaMarketplaceZone"),
                keccak256("1"),
                block.chainid,
                zoneAddress
            )
        );
    }

    function _signPermission(
        bytes32 orderHash,
        uint64 expiry,
        string memory definitionUrl,
        string memory disclosurePackageId
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = _buildDomainSeparator(address(zone));

        bytes32 structHash = keccak256(
            abi.encode(
                _EIP712_TYPE_HASH,
                orderHash,
                expiry,
                keccak256(bytes(definitionUrl)),
                keccak256(bytes(disclosurePackageId))
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildExtraData(
        uint64 expiry,
        string memory definitionUrl,
        string memory disclosurePackageId,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        bytes memory defUrlBytes = bytes(definitionUrl);
        bytes memory dpIdBytes = bytes(disclosurePackageId);

        // expiry (8 bytes) + defUrlLen (2 bytes) + defUrl (N bytes) + dpId (36 bytes) + sig
        return abi.encodePacked(expiry, uint16(defUrlBytes.length), defUrlBytes, dpIdBytes, signature);
    }

    function _buildZoneParameters(bytes32 orderHash, bytes memory extraData, address tokenAddress, uint256 tokenId)
        internal
        view
        returns (ZoneParameters memory)
    {
        // Build offer with ERC1155 item
        SpentItem[] memory offer = new SpentItem[](1);
        offer[0] = SpentItem({itemType: ItemType.ERC1155, token: tokenAddress, identifier: tokenId, amount: 1});

        ReceivedItem[] memory consideration = new ReceivedItem[](0);
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
            startTime: block.timestamp,
            endTime: block.timestamp + 1 days,
            zoneHash: bytes32(0)
        });
    }

    function testAuthorizeOrder_ValidSignatureNoDefinitionUrl() public {
        bytes32 orderHash = keccak256("test_order");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        string memory definitionUrl = "";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";

        bytes memory signature = _signPermission(orderHash, expiry, definitionUrl, disclosurePackageId);

        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, signature);

        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), 1);

        bytes4 result = zone.authorizeOrder(params);
        assertEq(result, FabricaMarketplaceZone.authorizeOrder.selector);
    }

    function testAuthorizeOrder_ValidSignatureWithDefinitionUrl() public {
        bytes32 orderHash = keccak256("test_order");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        string memory definitionUrl = "ipfs://QmTest123456789";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";
        uint256 tokenId = 42;

        // Set the definition URL on the mock token
        mockToken.setProperty(tokenId, definitionUrl);

        bytes memory signature = _signPermission(orderHash, expiry, definitionUrl, disclosurePackageId);

        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, signature);

        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), tokenId);

        bytes4 result = zone.authorizeOrder(params);
        assertEq(result, FabricaMarketplaceZone.authorizeOrder.selector);
    }

    function testRevert_DefinitionUrlMismatch() public {
        bytes32 orderHash = keccak256("test_order");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        string memory signedDefinitionUrl = "ipfs://QmSignedUrl";
        string memory onchainDefinitionUrl = "ipfs://QmOnchainUrl";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";
        uint256 tokenId = 42;

        // Set a different definition URL on the mock token
        mockToken.setProperty(tokenId, onchainDefinitionUrl);

        bytes memory signature = _signPermission(orderHash, expiry, signedDefinitionUrl, disclosurePackageId);

        bytes memory extraData = _buildExtraData(expiry, signedDefinitionUrl, disclosurePackageId, signature);

        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), tokenId);

        vm.expectRevert("Definition URL mismatch");
        zone.authorizeOrder(params);
    }

    function testRevert_ExpiredSignature() public {
        bytes32 orderHash = keccak256("test_order");
        uint64 expiry = uint64(block.timestamp - 1); // Already expired
        string memory definitionUrl = "";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";

        bytes memory signature = _signPermission(orderHash, expiry, definitionUrl, disclosurePackageId);

        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, signature);

        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), 1);

        vm.expectRevert("Oracle signature expired");
        zone.authorizeOrder(params);
    }

    function testRevert_ExpiryTooFar() public {
        bytes32 orderHash = keccak256("test_order");
        uint64 expiry = uint64(block.timestamp + 8 days); // Beyond MAX_AGE
        string memory definitionUrl = "";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";

        bytes memory signature = _signPermission(orderHash, expiry, definitionUrl, disclosurePackageId);

        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, signature);

        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), 1);

        vm.expectRevert("Expiry too far");
        zone.authorizeOrder(params);
    }

    function testRevert_BadSignature() public {
        bytes32 orderHash = keccak256("test_order");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        string memory definitionUrl = "";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";

        // Sign with a different private key
        uint256 wrongKey = 0xDEAD;
        bytes32 domainSeparator = _buildDomainSeparator(address(zone));
        bytes32 structHash = keccak256(
            abi.encode(
                _EIP712_TYPE_HASH,
                orderHash,
                expiry,
                keccak256(bytes(definitionUrl)),
                keccak256(bytes(disclosurePackageId))
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory wrongSignature = abi.encodePacked(r, s, v);

        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, wrongSignature);

        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), 1);

        vm.expectRevert("Bad oracle sig");
        zone.authorizeOrder(params);
    }

    function testRevert_ExtraDataTooShort() public {
        bytes32 orderHash = keccak256("test_order");

        ZoneParameters memory params = _buildZoneParameters(
            orderHash,
            hex"0000000000000000", // Only 8 bytes
            address(mockToken),
            1
        );

        vm.expectRevert("extraData too short");
        zone.authorizeOrder(params);
    }
}
