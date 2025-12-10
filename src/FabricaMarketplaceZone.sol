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

contract FabricaMarketplaceZone is ZoneInterface {
  using ECDSA for bytes32;

  // Immutable oracle signer (EOA or ERC‑1271 contract)
  address public immutable oracleSigner;
  uint256 public constant MAX_AGE = 7 days;

  // EIP‑712 domain separator (chainId baked in at deployment)
  bytes32 private immutable _DOMAIN_SEPARATOR;
  bytes32 private constant _EIP712_TYPE_HASH =
    keccak256(
      "OrderAuthorization(bytes32 orderHash,uint64 expiry,string disclosurePackageId)"
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

  /// @dev extraData = abi.encode(uint64 expiry, bytes36 disclosurePackageId, bytes signature)
  function _verify(
      ZoneParameters calldata p
  ) internal view {
    // pull the bytes slice out to its own calldata variable
    bytes calldata extra = p.extraData;
    if (extra.length <= 44) revert("extraData too short");
    // ------------------------------------------------------------------- //
    // 1.  Read the 8‑byte expiry (big‑endian) and copy the sig to memory
    // ------------------------------------------------------------------- //
    uint64 expiry;
    assembly {
    // first 8 bytes = uint64 BE; shift down to the low 64 bits
      expiry := shr(192, calldataload(extra.offset))
    }
    // next 36 bytes  -> ASCII UUID
    bytes memory dpId = extra[8:44];               // Solidity slice; calldata‑>memory

    // Solidity ≥0.8.22 supports slicing; this gives us a *memory* copy
    bytes memory sig  = extra[44:];                // remainder is the signature

    // ------------------------------------------------------------------- //
    // 2.  Fresh‑ness window
    // ------------------------------------------------------------------- //
    if (block.timestamp > expiry) revert("Oracle signature expired");
    if (expiry - block.timestamp > MAX_AGE) revert("Expiry too far");
    // ------------------------------------------------------------------- //
    // 3.  Re‑create the EIP‑712 digest
    // ------------------------------------------------------------------- //
    bytes32 digest = keccak256(
      abi.encodePacked(
        "\x19\x01",
        _DOMAIN_SEPARATOR,
        keccak256(abi.encode(
          _EIP712_TYPE_HASH,
          p.orderHash,
          expiry,
          keccak256(dpId)
        ))
      )
    );
    // ------------------------------------------------------------------- //
    // 4.  ECDSA (EOA)  or  ERC‑1271 (contract) check
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
