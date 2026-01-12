// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../lib/seaport-types/src/lib/ConsiderationStructs.sol";
import {ECDSA} from "../lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {ZoneInterface, ZoneParameters, Schema} from "seaport-types/interfaces/ZoneInterface.sol";

/// @dev For contract‑based signers you can replace ECDSA with ERC‑1271 checks
interface IERC1271 {
  function isValidSignature(
      bytes32 hash,
      bytes calldata sig
  ) external view returns (bytes4);
}

/// @dev Interface for FabricaToken to read the property definition
interface IFabricaToken {
  function _property(uint256 tokenId) external view returns (
    uint256 supply,
    string memory operatingAgreement,
    string memory definition,
    string memory configuration,
    address validator
  );
}

contract FabricaMarketplaceZone is ZoneInterface {
  using ECDSA for bytes32;

  // Immutable oracle signer (EOA or ERC‑1271 contract)
  address public immutable oracleSigner;
  uint256 public constant MAX_AGE = 7 days;

  // EIP‑712 domain separator (chainId baked in at deployment)
  bytes32 private immutable _DOMAIN_SEPARATOR;
  bytes32 private constant _EIP712_TYPE_HASH =
    keccak256(
      "OrderAuthorization(bytes32 orderHash,uint64 expiry,string definitionUrl,string disclosurePackageId)"
    );

  bytes4 private constant _AUTHORIZE_MAGIC = ZoneInterface.authorizeOrder.selector;
  bytes4 private constant _VALIDATE_MAGIC = ZoneInterface.validateOrder.selector;

  constructor(address _oracleSigner) {
    oracleSigner = _oracleSigner;
    _DOMAIN_SEPARATOR = _buildDomain();
  }

  /* ----------  Seaport hooks  ---------- */

  function authorizeOrder(
      ZoneParameters calldata p
  ) external view returns (bytes4) {
    _verify(p);
    return _AUTHORIZE_MAGIC;
  }

  function validateOrder(
      ZoneParameters calldata p
  ) external view returns (bytes4) {
    _verify(p); // redundant but cheap – protects post‑transfer state change
    return _VALIDATE_MAGIC;
  }

  /* ----------  Internal logic  ---------- */

  /// @dev extraData = [uint64 expiry (8 bytes)][uint16 definitionUrlLength (2 bytes)][bytes definitionUrl (N bytes)][bytes36 disclosurePackageId][bytes signature]
  function _verify(
      ZoneParameters calldata p
  ) internal view {
    // pull the bytes slice out to its own calldata variable
    bytes calldata extra = p.extraData;
    // Minimum: 8 (expiry) + 2 (defUrlLen) + 0 (defUrl) + 36 (dpId) + 65 (sig) = 111
    // But we accept shorter sigs, so min is 8 + 2 + 36 = 46 without sig
    if (extra.length < 46) revert("extraData too short");

    // ------------------------------------------------------------------- //
    // 1.  Read the 8‑byte expiry (big‑endian)
    // ------------------------------------------------------------------- //
    uint64 expiry;
    assembly {
      // first 8 bytes = uint64 BE; shift down to the low 64 bits
      expiry := shr(192, calldataload(extra.offset))
    }

    // ------------------------------------------------------------------- //
    // 2.  Read the 2-byte definition URL length (big-endian)
    // ------------------------------------------------------------------- //
    uint16 defUrlLen;
    assembly {
      // bytes 8-9 = uint16 BE; shift down to the low 16 bits
      defUrlLen := shr(240, calldataload(add(extra.offset, 8)))
    }

    // ------------------------------------------------------------------- //
    // 3.  Calculate offsets and extract data
    // ------------------------------------------------------------------- //
    uint256 defUrlStart = 10;
    uint256 defUrlEnd = defUrlStart + defUrlLen;
    uint256 dpIdStart = defUrlEnd;
    uint256 dpIdEnd = dpIdStart + 36;
    uint256 sigStart = dpIdEnd;

    if (extra.length < dpIdEnd) revert("extraData too short for definition URL");

    // definition URL (variable length)
    bytes memory defUrl = extra[defUrlStart:defUrlEnd];
    // next 36 bytes -> ASCII UUID for disclosure package
    bytes memory dpId = extra[dpIdStart:dpIdEnd];
    // remainder is the signature
    bytes memory sig = extra[sigStart:];

    // ------------------------------------------------------------------- //
    // 4.  Fresh‑ness window
    // ------------------------------------------------------------------- //
    if (block.timestamp > expiry) revert("Oracle signature expired");
    if (expiry - block.timestamp > MAX_AGE) revert("Expiry too far");

    // ------------------------------------------------------------------- //
    // 5.  Re‑create the EIP‑712 digest
    // ------------------------------------------------------------------- //
    bytes32 digest = keccak256(
      abi.encodePacked(
        "\x19\x01",
        _DOMAIN_SEPARATOR,
        keccak256(abi.encode(
          _EIP712_TYPE_HASH,
          p.orderHash,
          expiry,
          keccak256(defUrl),
          keccak256(dpId)
        ))
      )
    );

    // ------------------------------------------------------------------- //
    // 6.  ECDSA (EOA)  or  ERC‑1271 (contract) check
    // ------------------------------------------------------------------- //
    if (oracleSigner.code.length == 0) {
      // EOA signer
      address recovered = digest.recover(sig);
      if (recovered != oracleSigner) revert("Bad oracle sig");
    } else {
      // 1271 contract signer
      bytes4 ok = IERC1271(oracleSigner).isValidSignature(digest, sig);
      if (ok != IERC1271.isValidSignature.selector)
        revert("Bad oracle sig");
    }

    // ------------------------------------------------------------------- //
    // 7.  Verify definition URL matches onchain (if non-empty)
    // ------------------------------------------------------------------- //
    if (defUrlLen > 0) {
      _verifyDefinitionUrl(p, defUrl);
    }
  }

  /// @dev Finds the ERC1155 token in offer or consideration and verifies its definition URL
  function _verifyDefinitionUrl(
      ZoneParameters calldata p,
      bytes memory signedDefUrl
  ) internal view {
    // ItemType.ERC1155 = 3
    ItemType erc1155Type = ItemType.ERC1155;

    // Check offer items for ERC1155 (seller's listing)
    for (uint256 i = 0; i < p.offer.length; i++) {
      if (p.offer[i].itemType == erc1155Type) {
        _checkDefinition(p.offer[i].token, p.offer[i].identifier, signedDefUrl);
        return;
      }
    }

    // Check consideration items for ERC1155 (buyer's bid)
    for (uint256 i = 0; i < p.consideration.length; i++) {
      if (p.consideration[i].itemType == erc1155Type) {
        _checkDefinition(p.consideration[i].token, p.consideration[i].identifier, signedDefUrl);
        return;
      }
    }

    revert("No ERC1155 item found");
  }

  /// @dev Checks that the signed definition URL matches the onchain definition
  function _checkDefinition(
      address tokenContract,
      uint256 tokenId,
      bytes memory signedDefUrl
  ) internal view {
    // Get the property struct from FabricaToken
    (, , string memory onchainDefUrl, , ) = IFabricaToken(tokenContract)._property(tokenId);

    // Compare hashes (more gas efficient than string comparison)
    if (keccak256(bytes(onchainDefUrl)) != keccak256(signedDefUrl)) {
      revert("Definition URL mismatch");
    }
  }

  /* ----------  ERC‑165 & metadata  ---------- */

  function supportsInterface(bytes4 id) public pure override returns (bool) {
    return id == type(ZoneInterface).interfaceId;
  }

  function getSeaportMetadata() external pure override returns (string memory name, Schema[] memory schemas) {
    schemas = new Schema[](1);
    schemas[0] = Schema({ id: 3003, metadata: new bytes(0) });
    name = "FabricaMarketplaceZone";
  }

  function _buildDomain() private view returns (bytes32) {
    return keccak256(
      abi.encode(
        keccak256(
          "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        ),
        keccak256("FabricaMarketplaceZone"),
        keccak256("1"),
        block.chainid,
        address(this)
      )
    );
  }
}
