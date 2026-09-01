// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ZoneAuthorizationFixture} from "./ZoneAuthorizationFixture.sol";

/// @notice Models the parts of a Safe (v1.4.1) that decide whether a Safe can serve as
/// FabricaMarketplaceZone's `oracleSigner`, so the ENG-3687 item-2 finding is executable in
/// ordinary CI with no RPC.
/// @dev Lives in its own file, not inside a `.t.sol`, deliberately: the Sepolia attestation
/// carries an explicit sunset (retire with the item-2 cutover) while this model is permanent CI
/// coverage. Keeping them in separate files means retiring the attestation cannot silently
/// delete the model.
/// @dev FIDELITY BOUNDARY — read before writing a rejection test against this.
/// MODELLED, and pinned against the live Safe by the attestation's re-wrap differential: the
/// SafeMessage EIP-712 re-wrap; `signedMessages` (empty-signature) short-circuit, which correctly
/// precedes the length gate; the GS020 length gate; strict ascending-owner ordering; ECDSA owners
/// (v in {27,28}); eth_sign owners (v > 30); and `setupOwners`' GS201/GS202/GS203/GS204 guards.
/// NOT MODELLED: modules, guards, contract-signature owners (v == 0, real Safe reverts GS022) and
/// pre-approved-hash owner SLOTS (v == 1, real Safe reverts GS025). For those two owner types this
/// model recovers address(0) and reverts GS026, so a rejection observed here does NOT transfer to
/// a real Safe. Acceptance results transfer; rejection results transfer only for modelled
/// branches.
/// @dev Two further divergences worth naming because they understate real Safe's cost, not its
/// behaviour. `markMessageSigned` is unauthenticated, whereas a real Safe writes `signedMessages`
/// only via a `SignMessageLib` delegatecall executed as a full Safe transaction — i.e. it costs a
/// threshold. And the eth_sign branch is verified against Safe v1.4.1 source only; unlike the
/// re-wrap formula it has no live differential pin, because no eth_sign-owner Safe is among the
/// pinned Sepolia fixtures.
contract SafeLikeErc1271Signer {
    bytes4 private constant _ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes32 private constant _SAFE_MSG_TYPEHASH = keccak256("SafeMessage(bytes message)");
    bytes32 private constant _DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    address private constant _SENTINEL_OWNER = address(0x1);

    address[] private _owners;
    uint256 private _threshold;
    mapping(bytes32 => uint256) private _signedMessages;

    /// @dev Mirrors Safe's `setupOwners`, including which guard reports which code: an ADJACENT
    /// duplicate is caught by the GS203 require (real Safe folds `currentOwner != owner` into it),
    /// while a non-adjacent duplicate is caught by the owner-already-registered check as GS204.
    constructor(address[] memory owners_, uint256 threshold_) {
        require(threshold_ <= owners_.length, "GS201");
        require(threshold_ >= 1, "GS202");
        address currentOwner = _SENTINEL_OWNER;
        for (uint256 i = 0; i < owners_.length; i++) {
            address owner = owners_[i];
            require(
                owner != address(0) && owner != _SENTINEL_OWNER && owner != address(this) && currentOwner != owner,
                "GS203"
            );
            for (uint256 j = 0; j < i; j++) {
                require(owners_[j] != owner, "GS204");
            }
            currentOwner = owner;
        }
        _owners = owners_;
        _threshold = threshold_;
    }

    /// @dev Mirrors `SignMessageLib.signMessage` writing Safe's `signedMessages` mapping — the
    /// empty-signature channel. This is NOT `Safe.approveHash`, which writes the separate
    /// `approvedHashes` mapping consumed by the v == 1 owner slot and is not modelled here.
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
        bytes memory blob = signature;
        address lastOwner = address(0);
        for (uint256 i = 0; i < _threshold; i++) {
            address currentOwner = ZoneAuthorizationFixture.recoverOwnerAt(blob, i, messageHash);
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
}
