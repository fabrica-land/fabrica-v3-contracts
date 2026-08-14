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

contract MockERC1271Signer {
    bytes4 private constant _ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 private constant _INVALID_SIGNATURE_VALUE = 0xffffffff;

    mapping(bytes32 => bool) public validSignatures;

    function setValidSignature(bytes32 digest, bytes memory signature, bool valid) external {
        validSignatures[keccak256(abi.encode(digest, signature))] = valid;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (validSignatures[keccak256(abi.encode(hash, signature))]) {
            return _ERC1271_MAGIC_VALUE;
        }
        return _INVALID_SIGNATURE_VALUE;
    }
}

/// @notice Models the parts of a Safe (v1.4.1) that decide whether a Safe can serve as the
/// zone's `oracleSigner`: the SafeMessage EIP-712 re-wrap performed by
/// CompatibilityFallbackHandler.isValidSignature, and checkSignatures' length gate plus
/// strictly-ascending owner recovery.
/// @dev Deliberately NOT a general Safe implementation — no modules, guards, eth_sign (v>30),
/// contract-signature (v=0) or pre-approved-hash (v=1) owner types. It exists so the ENG-3687
/// finding is executable in CI without an RPC; the live Safe is attested against separately in
/// FabricaMarketplaceZoneSepoliaErc1271Fork.t.sol.
contract SafeLikeErc1271Signer {
    bytes4 private constant _ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes32 private constant _SAFE_MSG_TYPEHASH = keccak256("SafeMessage(bytes message)");
    bytes32 private constant _DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");

    address[] public owners;
    uint256 public threshold;

    constructor(address[] memory _owners, uint256 _threshold) {
        require(_threshold > 0 && _threshold <= _owners.length, "bad threshold");
        owners = _owners;
        threshold = _threshold;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    /// @dev The re-wrap: a Safe never checks signatures against the hash it is handed.
    function getMessageHash(bytes memory message) public view returns (bytes32) {
        bytes32 safeMessageHash = keccak256(abi.encode(_SAFE_MSG_TYPEHASH, keccak256(message)));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator(), safeMessageHash));
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        bytes32 messageHash = getMessageHash(abi.encode(hash));
        require(signature.length >= threshold * 65, "GS020");
        address lastOwner = address(0);
        for (uint256 i = 0; i < threshold; i++) {
            (uint8 v, bytes32 r, bytes32 s) = _splitSignature(signature, i);
            address currentOwner = ecrecover(messageHash, v, r, s);
            require(currentOwner > lastOwner && _isOwner(currentOwner), "GS026");
            lastOwner = currentOwner;
        }
        return _ERC1271_MAGIC_VALUE;
    }

    function _isOwner(address candidate) private view returns (bool) {
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == candidate) {
                return true;
            }
        }
        return false;
    }

    function _splitSignature(bytes calldata signature, uint256 index)
        private
        pure
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        uint256 offset = index * 65;
        r = bytes32(signature[offset:offset + 32]);
        s = bytes32(signature[offset + 32:offset + 64]);
        v = uint8(signature[offset + 64]);
    }
}

contract FabricaMarketplaceZoneTest is Test {
    string internal constant ZERO_UUID = "00000000-0000-0000-0000-000000000000";

    FabricaMarketplaceZone public zone;
    MockFabricaToken public mockToken;
    MockERC1271Signer public mock1271Signer;

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
        mock1271Signer = new MockERC1271Signer();
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

    function _buildPermissionDigest(
        address zoneAddress,
        bytes32 orderHash,
        uint64 expiry,
        string memory definitionUrl,
        string memory disclosurePackageId
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = _buildDomainSeparator(zoneAddress);
        bytes32 structHash = keccak256(
            abi.encode(
                _EIP712_TYPE_HASH,
                orderHash,
                expiry,
                keccak256(bytes(definitionUrl)),
                keccak256(bytes(disclosurePackageId))
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
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

    function testERC1271Signer_AuthorizeAndValidateOrderWithExactDigestAndSignature() public {
        FabricaMarketplaceZone contractSignerZone = new FabricaMarketplaceZone(address(mock1271Signer));
        bytes32 orderHash = keccak256("erc1271_order");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        string memory definitionUrl = "";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";
        bytes memory signature = hex"1234";
        bytes32 digest =
            _buildPermissionDigest(address(contractSignerZone), orderHash, expiry, definitionUrl, disclosurePackageId);
        mock1271Signer.setValidSignature(digest, signature, true);
        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, signature);
        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), 1);

        assertEq(contractSignerZone.authorizeOrder(params), FabricaMarketplaceZone.authorizeOrder.selector);
        assertEq(contractSignerZone.validateOrder(params), FabricaMarketplaceZone.validateOrder.selector);
    }

    function testERC1271Signer_RejectsOldEoaSignaturePath() public {
        FabricaMarketplaceZone contractSignerZone = new FabricaMarketplaceZone(address(mock1271Signer));
        bytes32 orderHash = keccak256("erc1271_rejects_eoa");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        string memory definitionUrl = "";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";
        bytes32 digest =
            _buildPermissionDigest(address(contractSignerZone), orderHash, expiry, definitionUrl, disclosurePackageId);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        bytes memory oldEoaSignature = abi.encodePacked(r, s, v);
        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, oldEoaSignature);
        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), 1);

        vm.expectRevert("Bad oracle sig");
        contractSignerZone.authorizeOrder(params);
    }

    function testERC1271Signer_RejectsWrongDigestOrSignature() public {
        FabricaMarketplaceZone contractSignerZone = new FabricaMarketplaceZone(address(mock1271Signer));
        bytes32 orderHash = keccak256("erc1271_wrong_signature");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        string memory definitionUrl = "";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";
        bytes memory validSignature = hex"1234";
        bytes memory wrongSignature = hex"5678";
        bytes32 digest =
            _buildPermissionDigest(address(contractSignerZone), orderHash, expiry, definitionUrl, disclosurePackageId);
        mock1271Signer.setValidSignature(digest, validSignature, true);
        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, wrongSignature);
        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), 1);

        vm.expectRevert("Bad oracle sig");
        contractSignerZone.authorizeOrder(params);
    }

    function testERC1271Signer_RejectsExpiredSignature() public {
        FabricaMarketplaceZone contractSignerZone = new FabricaMarketplaceZone(address(mock1271Signer));
        bytes32 orderHash = keccak256("erc1271_expired");
        uint64 expiry = uint64(block.timestamp - 1);
        string memory definitionUrl = "";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";
        bytes memory signature = hex"1234";
        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, signature);
        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), 1);

        vm.expectRevert("Oracle signature expired");
        contractSignerZone.authorizeOrder(params);
    }

    function testERC1271Signer_RejectsExpiryBeyondMaxAge() public {
        FabricaMarketplaceZone contractSignerZone = new FabricaMarketplaceZone(address(mock1271Signer));
        bytes32 orderHash = keccak256("erc1271_expiry_too_far");
        uint64 expiry = uint64(block.timestamp + 8 days);
        string memory definitionUrl = "";
        string memory disclosurePackageId = "12345678-1234-1234-1234-123456789012";
        bytes memory signature = hex"1234";
        bytes memory extraData = _buildExtraData(expiry, definitionUrl, disclosurePackageId, signature);
        ZoneParameters memory params = _buildZoneParameters(orderHash, extraData, address(mockToken), 1);

        vm.expectRevert("Expiry too far");
        contractSignerZone.authorizeOrder(params);
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

    /* ----------  ENG-3687: Safe-shaped ERC-1271 signer  ---------- */

    /// @dev The MockERC1271Signer above is a lookup table: it proves the zone CALLS a contract
    /// signer, not that a real Safe would accept what we send it. SafeLikeErc1271Signer models
    /// the two Safe behaviours that actually decide whether a Safe deployment works — the
    /// SafeMessage domain re-wrap and the owner/threshold check — so these run in ordinary CI
    /// with no RPC. The live Sepolia attestation is in FabricaMarketplaceZoneSepoliaErc1271Fork.

    function testSafeLikeSigner_AcceptsSignaturesOverTheSafeMessageHash() public {
        uint256[] memory keys = new uint256[](2);
        keys[0] = 0xB0B;
        keys[1] = 0xCA7;
        SafeLikeErc1271Signer safeSigner = _deploySafeLikeSigner(keys, 2);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_accepts");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        bytes memory signature = _signAsOwners(keys, safeSigner.getMessageHash(abi.encode(digest)));
        ZoneParameters memory params =
            _buildZoneParameters(orderHash, _buildExtraData(expiry, "", ZERO_UUID, signature), address(mockToken), 1);

        assertEq(safeZone.authorizeOrder(params), FabricaMarketplaceZone.authorizeOrder.selector);
        assertEq(safeZone.validateOrder(params), FabricaMarketplaceZone.validateOrder.selector);
    }

    /// @dev ENG-3687's hand-off to item 2, pinned as an executable claim: the signature shape
    /// fabrica-v3-api produces today — ONE EOA signing the raw zone digest — does not
    /// authenticate against a Safe. Threshold is 1 here deliberately, so the failure cannot be
    /// explained away by a signature-length check.
    function testSafeLikeSigner_RejectsEoaSignatureOverRawZoneDigest_EvenAtThresholdOne() public {
        uint256[] memory keys = new uint256[](1);
        keys[0] = 0xB0B;
        SafeLikeErc1271Signer safeSigner = _deploySafeLikeSigner(keys, 1);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_rejects_raw_digest");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        // sign the zone digest directly, exactly as marketplace.service.ts does today
        bytes memory apiShapedSignature = _signAsOwners(keys, digest);
        bytes memory safeAwareSignature = _signAsOwners(keys, safeSigner.getMessageHash(abi.encode(digest)));
        assertEq(apiShapedSignature.length, safeAwareSignature.length, "controls must be the same length");
        ZoneParameters memory rejected = _buildZoneParameters(
            orderHash, _buildExtraData(expiry, "", ZERO_UUID, apiShapedSignature), address(mockToken), 1
        );
        ZoneParameters memory accepted = _buildZoneParameters(
            orderHash, _buildExtraData(expiry, "", ZERO_UUID, safeAwareSignature), address(mockToken), 1
        );

        // the Safe reverts internally rather than returning a non-magic value, so the zone's own
        // "Bad oracle sig" branch is never reached — alerting must match the Safe's errors
        vm.expectRevert(bytes("GS026"));
        safeZone.authorizeOrder(rejected);
        assertEq(safeZone.authorizeOrder(accepted), FabricaMarketplaceZone.authorizeOrder.selector);
    }

    function testSafeLikeSigner_RejectsSignaturesBelowThreshold() public {
        uint256[] memory keys = new uint256[](2);
        keys[0] = 0xB0B;
        keys[1] = 0xCA7;
        SafeLikeErc1271Signer safeSigner = _deploySafeLikeSigner(keys, 2);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_below_threshold");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        uint256[] memory onlyOne = new uint256[](1);
        onlyOne[0] = keys[0];
        bytes memory signature = _signAsOwners(onlyOne, safeSigner.getMessageHash(abi.encode(digest)));
        ZoneParameters memory params =
            _buildZoneParameters(orderHash, _buildExtraData(expiry, "", ZERO_UUID, signature), address(mockToken), 1);

        vm.expectRevert(bytes("GS020"));
        safeZone.authorizeOrder(params);
    }

    function testSafeLikeSigner_RejectsNonOwnerSignatures() public {
        uint256[] memory keys = new uint256[](1);
        keys[0] = 0xB0B;
        SafeLikeErc1271Signer safeSigner = _deploySafeLikeSigner(keys, 1);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_non_owner");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        uint256[] memory stranger = new uint256[](1);
        stranger[0] = 0xDEC0DE;
        bytes memory signature = _signAsOwners(stranger, safeSigner.getMessageHash(abi.encode(digest)));
        ZoneParameters memory params =
            _buildZoneParameters(orderHash, _buildExtraData(expiry, "", ZERO_UUID, signature), address(mockToken), 1);

        vm.expectRevert(bytes("GS026"));
        safeZone.authorizeOrder(params);
    }

    /// @dev Owners must be supplied to the signer in ascending address order, which is also the
    /// order their signatures must be concatenated in.
    function _deploySafeLikeSigner(uint256[] memory privateKeys, uint256 threshold)
        internal
        returns (SafeLikeErc1271Signer)
    {
        address[] memory owners = new address[](privateKeys.length);
        for (uint256 i = 0; i < privateKeys.length; i++) {
            owners[i] = vm.addr(privateKeys[i]);
        }
        _sortAscending(owners, privateKeys);
        return new SafeLikeErc1271Signer(owners, threshold);
    }

    function _signAsOwners(uint256[] memory privateKeys, bytes32 hashToSign) internal pure returns (bytes memory) {
        bytes memory signatures;
        for (uint256 i = 0; i < privateKeys.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKeys[i], hashToSign);
            signatures = abi.encodePacked(signatures, r, s, v);
        }
        return signatures;
    }

    function _sortAscending(address[] memory owners, uint256[] memory privateKeys) internal pure {
        for (uint256 i = 1; i < owners.length; i++) {
            for (uint256 j = i; j > 0 && owners[j - 1] > owners[j]; j--) {
                (owners[j - 1], owners[j]) = (owners[j], owners[j - 1]);
                (privateKeys[j - 1], privateKeys[j]) = (privateKeys[j], privateKeys[j - 1]);
            }
        }
    }
}
