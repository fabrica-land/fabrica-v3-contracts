// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ZoneInterface, ZoneParameters, Schema} from "seaport-types/interfaces/ZoneInterface.sol";
import {ECDSA} from "../lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

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
  uint256 public constant MAX_AGE = 24 seconds;

  // EIP‑712 domain separator (chainId baked in at deployment)
  bytes32 private immutable _DOMAIN_SEPARATOR;
  bytes32 private constant _EIP712_TYPE_HASH =
    keccak256(
      "OrderAuthorization(bytes32 orderHash,address fulfiller,uint64 expiry)"
    );

  bytes4 private constant _MAGIC = ZoneInterface.validateOrder.selector;

  constructor(address _oracleSigner) {
    oracleSigner = _oracleSigner;
    _DOMAIN_SEPARATOR = _buildDomain();
  }

  /* ----------  Seaport hooks  ---------- */

  function authorizeOrder(
      ZoneParameters calldata p
  ) external view returns (bytes4) {
    _verify(p);
    return _MAGIC;
  }

  function validateOrder(
      ZoneParameters calldata p
  ) external view returns (bytes4) {
    _verify(p); // redundant but cheap – protects post‑transfer state change
    return _MAGIC;
  }

  /* ----------  Internal logic  ---------- */

  /// @dev extraData = abi.encode(uint64 expiry, bytes signature)
  function _verify(
      ZoneParameters calldata p
  ) internal view {
    // pull the bytes slice out to its own calldata variable
    bytes calldata extra = p.extraData;
    // ------------------------------------------------------------------- //
    // 1.  Read the 8‑byte expiry (big‑endian) and copy the sig to memory
    // ------------------------------------------------------------------- //
    if (extra.length <= 8) revert("extraData too short");
    uint64 expiry;
    assembly {
    // first 8 bytes = uint64 BE; shift down to the low 64 bits
      expiry := shr(192, calldataload(extra.offset))
    }
    // Solidity ≥0.8.22 supports slicing; this gives us a *memory* copy
    bytes memory sig = extra[8:];
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
          p.fulfiller,
          expiry
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
