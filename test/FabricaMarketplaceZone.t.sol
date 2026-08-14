// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FabricaMarketplaceZone} from "../src/FabricaMarketplaceZone.sol";
import {ZoneAuthorizationFixture} from "./ZoneAuthorizationFixture.sol";
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
/// CompatibilityFallbackHandler.isValidSignature, the empty-signature pre-approved-message
/// branch, and checkSignatures' length gate plus strictly-ascending owner recovery.
/// @dev Fidelity boundary — READ BEFORE WRITING A REJECTION TEST AGAINST THIS. Modelled: the
/// SafeMessage re-wrap, `signedMessages` (empty signature), the GS020 length gate, strict
/// ascending-owner ordering, ECDSA owners with v in {27,28}, and eth_sign owners with v > 30.
/// NOT modelled: modules, guards, contract-signature owners (v == 0, real Safe reverts GS022)
/// and pre-approved-hash owner slots (v == 1, real Safe reverts GS025 / GS026 wording differs).
/// For those two owner types this model recovers address(0) and reverts GS026, so a rejection
/// observed here does NOT transfer to a real Safe — it may reject for a different reason, or in
/// the v == 1 case accept where this model rejects. Acceptance results transfer; rejection
/// results transfer only for the modelled branches. The live Safe is attested against separately
/// in FabricaMarketplaceZoneSepoliaErc1271Fork.t.sol.
contract SafeLikeErc1271Signer {
    bytes4 private constant _ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes32 private constant _SAFE_MSG_TYPEHASH = keccak256("SafeMessage(bytes message)");
    bytes32 private constant _DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    address private constant _SENTINEL_OWNER = address(0x1);

    address[] private _owners;
    uint256 private _threshold;
    mapping(bytes32 => uint256) private _signedMessages;

    constructor(address[] memory owners_, uint256 threshold_) {
        require(threshold_ > 0 && threshold_ <= owners_.length, "bad threshold");
        for (uint256 i = 0; i < owners_.length; i++) {
            address owner = owners_[i];
            // real Safe's setupOwners rejects these outright; without the guard a malformed
            // signature recovering to address(0) would validate as a zero-address owner
            require(owner != address(0) && owner != _SENTINEL_OWNER && owner != address(this), "GS203");
            for (uint256 j = 0; j < i; j++) {
                require(owners_[j] != owner, "GS204");
            }
        }
        _owners = owners_;
        _threshold = threshold_;
    }

    /// @dev Mirrors Safe.approveHash / SignMessageLib: marks a message hash valid with no
    /// signature bytes at all.
    function markMessageSigned(bytes32 messageHash) external {
        _signedMessages[messageHash] = 1;
    }

    /// @dev The re-wrap: a Safe never checks signatures against the hash it is handed.
    function getMessageHash(bytes memory message) public view returns (bytes32) {
        bytes32 safeMessageHash = keccak256(abi.encode(_SAFE_MSG_TYPEHASH, keccak256(message)));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), _domainSeparator(), safeMessageHash));
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        bytes32 messageHash = getMessageHash(abi.encode(hash));
        // real Safe short-circuits to the pre-approved-message store before any length check
        if (signature.length == 0) {
            require(_signedMessages[messageHash] != 0, "Hash not approved");
            return _ERC1271_MAGIC_VALUE;
        }
        require(signature.length >= _threshold * 65, "GS020");
        address lastOwner = address(0);
        for (uint256 i = 0; i < _threshold; i++) {
            (uint8 v, bytes32 r, bytes32 s) = _splitSignature(signature, i);
            address currentOwner;
            if (v > 30) {
                // eth_sign owners: Safe re-hashes with the personal-sign prefix and subtracts 4
                currentOwner = ecrecover(
                    keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)), v - 4, r, s
                );
            } else {
                currentOwner = ecrecover(messageHash, v, r, s);
            }
            require(currentOwner > lastOwner && _isOwner(currentOwner), "GS026");
            lastOwner = currentOwner;
        }
        return _ERC1271_MAGIC_VALUE;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    function _isOwner(address candidate) private view returns (bool) {
        for (uint256 i = 0; i < _owners.length; i++) {
            if (_owners[i] == candidate) {
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
        return ZoneAuthorizationFixture.buildExtraData(expiry, definitionUrl, disclosurePackageId, signature);
    }

    function _buildZoneParameters(bytes32 orderHash, bytes memory extraData, address tokenAddress, uint256 tokenId)
        internal
        view
        returns (ZoneParameters memory)
    {
        return ZoneAuthorizationFixture.buildZoneParameters(
            orderHash, extraData, tokenAddress, tokenId, block.timestamp, block.timestamp + 1 days
        );
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

    // The MockERC1271Signer above is a lookup table: it proves the zone CALLS a contract signer
    // and can return a non-magic value, not that a real Safe would accept what we send it.
    // SafeLikeErc1271Signer models the Safe behaviours that decide whether a Safe deployment
    // works, so the ENG-3687 item-2 finding runs in ordinary CI with no RPC. Its fidelity to the
    // live Safe is pinned by a differential assertion in the Sepolia fork attestation.
    // Owner keys are ordered so `_deploySafeLikeSigner` must actually reorder them — otherwise
    // the ascending-order pairing logic would never execute in any test.

    function testSafeLikeSigner_AcceptsSignaturesOverTheSafeMessageHash() public {
        uint256[] memory keys = new uint256[](2);
        keys[0] = 0xCA7;
        keys[1] = 0xB0B;
        (SafeLikeErc1271Signer safeSigner, uint256[] memory sortedKeys) = _deploySafeLikeSigner(keys, 2);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_accepts");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        bytes memory signature = _signAsOwners(sortedKeys, safeSigner.getMessageHash(abi.encode(digest)));
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
        (SafeLikeErc1271Signer safeSigner, uint256[] memory sortedKeys) = _deploySafeLikeSigner(keys, 1);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_rejects_raw_digest");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        // sign the zone digest directly, exactly as marketplace.service.ts does today
        bytes memory apiShaped = _signAsOwners(sortedKeys, digest);
        bytes memory safeAware = _signAsOwners(sortedKeys, safeSigner.getMessageHash(abi.encode(digest)));
        assertEq(apiShaped.length, safeAware.length, "controls must be the same length");
        _expectBothEntryPointsRevert(safeZone, orderHash, expiry, apiShaped, "GS026");
        ZoneParameters memory accepted =
            _buildZoneParameters(orderHash, _buildExtraData(expiry, "", ZERO_UUID, safeAware), address(mockToken), 1);
        assertEq(safeZone.authorizeOrder(accepted), FabricaMarketplaceZone.authorizeOrder.selector);
    }

    function testSafeLikeSigner_RejectsSignaturesBelowThreshold() public {
        uint256[] memory keys = new uint256[](2);
        keys[0] = 0xCA7;
        keys[1] = 0xB0B;
        (SafeLikeErc1271Signer safeSigner, uint256[] memory sortedKeys) = _deploySafeLikeSigner(keys, 2);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_below_threshold");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        uint256[] memory onlyOne = new uint256[](1);
        onlyOne[0] = sortedKeys[0];
        bytes memory signature = _signAsOwners(onlyOne, safeSigner.getMessageHash(abi.encode(digest)));
        _expectBothEntryPointsRevert(safeZone, orderHash, expiry, signature, "GS020");
    }

    function testSafeLikeSigner_RejectsNonOwnerSignatures() public {
        uint256[] memory keys = new uint256[](1);
        keys[0] = 0xB0B;
        (SafeLikeErc1271Signer safeSigner,) = _deploySafeLikeSigner(keys, 1);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_non_owner");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        uint256[] memory stranger = new uint256[](1);
        stranger[0] = 0xDEC0DE;
        bytes memory signature = _signAsOwners(stranger, safeSigner.getMessageHash(abi.encode(digest)));
        _expectBothEntryPointsRevert(safeZone, orderHash, expiry, signature, "GS026");
    }

    /// @dev Owner signatures must be concatenated in ascending owner-address order — half of the
    /// instruction the item-2 hand-off gives the API implementer, so it needs a failing case.
    function testSafeLikeSigner_RejectsDescendingOwnerOrder() public {
        uint256[] memory keys = new uint256[](2);
        keys[0] = 0xCA7;
        keys[1] = 0xB0B;
        (SafeLikeErc1271Signer safeSigner, uint256[] memory sortedKeys) = _deploySafeLikeSigner(keys, 2);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_descending");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        uint256[] memory descending = new uint256[](2);
        descending[0] = sortedKeys[1];
        descending[1] = sortedKeys[0];
        bytes memory signature = _signAsOwners(descending, safeSigner.getMessageHash(abi.encode(digest)));
        _expectBothEntryPointsRevert(safeZone, orderHash, expiry, signature, "GS026");
    }

    /// @dev The channel item-2 hand-off finding 4 is about: with the message pre-approved on the
    /// Safe, an order authorizes with ZERO signature bytes in extraData.
    function testSafeLikeSigner_AcceptsPreApprovedMessageWithEmptySignature() public {
        uint256[] memory keys = new uint256[](1);
        keys[0] = 0xB0B;
        (SafeLikeErc1271Signer safeSigner,) = _deploySafeLikeSigner(keys, 1);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_pre_approved");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        ZoneParameters memory params =
            _buildZoneParameters(orderHash, _buildExtraData(expiry, "", ZERO_UUID, ""), address(mockToken), 1);
        // before pre-approval the empty-signature path is closed
        vm.expectRevert(bytes("Hash not approved"));
        safeZone.authorizeOrder(params);
        safeSigner.markMessageSigned(safeSigner.getMessageHash(abi.encode(digest)));
        assertEq(safeZone.authorizeOrder(params), FabricaMarketplaceZone.authorizeOrder.selector);
    }

    /// @dev eth_sign owners (v > 30) are accepted by a real Safe, so the model accepts them too —
    /// otherwise every rejection test written against it would be a false negative.
    function testSafeLikeSigner_AcceptsEthSignOwnerSignature() public {
        uint256[] memory keys = new uint256[](1);
        keys[0] = 0xB0B;
        (SafeLikeErc1271Signer safeSigner,) = _deploySafeLikeSigner(keys, 1);
        FabricaMarketplaceZone safeZone = new FabricaMarketplaceZone(address(safeSigner));
        bytes32 orderHash = keccak256("safe_like_eth_sign");
        uint64 expiry = uint64(block.timestamp + 1 hours);
        bytes32 digest = _buildPermissionDigest(address(safeZone), orderHash, expiry, "", ZERO_UUID);
        bytes32 safeMessageHash = safeSigner.getMessageHash(abi.encode(digest));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(keys[0], keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", safeMessageHash)));
        bytes memory signature = abi.encodePacked(r, s, v + 4);
        ZoneParameters memory params =
            _buildZoneParameters(orderHash, _buildExtraData(expiry, "", ZERO_UUID, signature), address(mockToken), 1);
        assertEq(safeZone.authorizeOrder(params), FabricaMarketplaceZone.authorizeOrder.selector);
    }

    function testSafeLikeSigner_RejectsZeroAddressOwner() public {
        address[] memory owners = new address[](1);
        owners[0] = address(0);
        vm.expectRevert(bytes("GS203"));
        new SafeLikeErc1271Signer(owners, 1);
    }

    function testSafeLikeSigner_RejectsDuplicateOwners() public {
        address[] memory owners = new address[](2);
        owners[0] = vm.addr(0xB0B);
        owners[1] = vm.addr(0xB0B);
        vm.expectRevert(bytes("GS204"));
        new SafeLikeErc1271Signer(owners, 2);
    }

    /// @dev Both zone entry points run the same `_verify` guard. Asserting only `authorizeOrder`
    /// leaves `validateOrder` unprotected — deleting `_verify` from it passed the whole suite
    /// before this helper existed.
    function _expectBothEntryPointsRevert(
        FabricaMarketplaceZone safeZone,
        bytes32 orderHash,
        uint64 expiry,
        bytes memory signature,
        string memory reason
    ) internal {
        ZoneParameters memory params = _buildZoneParameters(
            orderHash, _buildExtraData(expiry, "", ZERO_UUID, signature), address(mockToken), 1
        );
        vm.expectRevert(bytes(reason));
        safeZone.authorizeOrder(params);
        vm.expectRevert(bytes(reason));
        safeZone.validateOrder(params);
    }

    /// @dev Returns the keys re-ordered to match the Safe's ascending owner list, so callers sign
    /// in the order `checkSignatures` requires. Returned explicitly rather than mutated in place.
    function _deploySafeLikeSigner(uint256[] memory privateKeys, uint256 threshold)
        internal
        returns (SafeLikeErc1271Signer, uint256[] memory)
    {
        address[] memory owners = new address[](privateKeys.length);
        uint256[] memory sortedKeys = new uint256[](privateKeys.length);
        for (uint256 i = 0; i < privateKeys.length; i++) {
            owners[i] = vm.addr(privateKeys[i]);
            sortedKeys[i] = privateKeys[i];
        }
        _sortAscending(owners, sortedKeys);
        return (new SafeLikeErc1271Signer(owners, threshold), sortedKeys);
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
