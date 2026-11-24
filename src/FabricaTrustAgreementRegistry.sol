// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFabricaToken} from "./IFabricaToken.sol";

/// @dev An immutable data container. STOP prevents execution of the payload.
contract FabricaTrustAgreementData {
    constructor(bytes memory data) {
        bytes memory runtime = abi.encodePacked(hex"00", data);
        assembly ("memory-safe") {
            return(add(runtime, 32), mload(runtime))
        }
    }
}

/// @notice Ownerless, write-once storage of exact content-addressed agreement bytes.
/// @dev Supports sha2-256 raw CIDv1 and single-file, single-node UnixFS CIDv0/v1.
///      It rejects other encodings rather than interpreting or normalizing text.
contract FabricaTrustAgreementRegistry {
    struct Agreement {
        bytes32 contentHash;
        uint256 byteLength;
        address[] chunks;
    }

    uint256 public constant MAX_CHUNK_BYTES = 24_000;
    uint256 public constant MAX_TEXT_BYTES = 262_144;
    IFabricaToken public immutable token;
    mapping(string => Agreement) private _agreements;
    mapping(address => bool) public isChunk;

    error AgreementAlreadyStored(string ipfsAddress);
    error AgreementNotStored(string ipfsAddress);
    error ContentAddressMismatch();
    error InvalidTextLength(uint256 length);
    error InvalidChunk(address chunk);
    error InvalidChunkLength(uint256 length);
    error InvalidTokenContract();

    event ChunkWritten(address indexed chunk, bytes32 indexed contentHash, uint256 byteLength);

    event AgreementStored(string ipfsAddress, bytes32 indexed contentHash, uint256 byteLength);

    constructor(address tokenContract) {
        if (tokenContract.code.length == 0) revert InvalidTokenContract();
        token = IFabricaToken(tokenContract);
    }

    /// @notice Stage one immutable chunk. Each transaction stays below code-size limits.
    function writeChunk(bytes calldata data) external returns (address chunk) {
        if (data.length == 0 || data.length > MAX_CHUNK_BYTES) revert InvalidChunkLength(data.length);
        chunk = address(new FabricaTrustAgreementData(data));
        isChunk[chunk] = true;
        emit ChunkWritten(chunk, sha256(data), data.length);
    }

    /// @notice Register staged chunks only when their complete bytes match the URI.
    /// @dev Anyone can finalize. No partial agreement is visible before this call.
    function store(string calldata ipfsAddress, address[] calldata chunks) external {
        if (_agreements[ipfsAddress].byteLength != 0) revert AgreementAlreadyStored(ipfsAddress);
        uint256 length;
        for (uint256 i; i < chunks.length; ++i) {
            if (!isChunk[chunks[i]]) revert InvalidChunk(chunks[i]);
            length += chunks[i].code.length - 1;
            if (length > MAX_TEXT_BYTES) revert InvalidTextLength(length);
        }
        if (length == 0) revert InvalidTextLength(length);
        bytes memory data = _readChunks(chunks, length);
        bytes32 contentHash = sha256(data);
        if (!_matchesContentAddress(ipfsAddress, data, contentHash)) revert ContentAddressMismatch();
        Agreement storage entry = _agreements[ipfsAddress];
        entry.contentHash = contentHash;
        entry.byteLength = length;
        entry.chunks = chunks;
        emit AgreementStored(ipfsAddress, contentHash, length);
    }

    /// @notice Returns every original byte, with no gateway or name lookup.
    function text(string memory ipfsAddress) public view returns (string memory) {
        Agreement storage entry = _agreements[ipfsAddress];
        uint256 length = entry.byteLength;
        if (length == 0) revert AgreementNotStored(ipfsAddress);
        return string(_readChunks(entry.chunks, length));
    }

    function _readChunks(address[] memory chunks, uint256 length) private view returns (bytes memory result) {
        result = new bytes(length);
        uint256 offset;
        for (uint256 i; i < chunks.length; ++i) {
            address chunk = chunks[i];
            uint256 size = chunk.code.length - 1;
            assembly ("memory-safe") {
                extcodecopy(chunk, add(add(result, 32), offset), 1, size)
            }
            offset += size;
        }
    }

    /// @notice Resolves the pinned token contract's current agreement pointer.
    /// @dev Retained pointers on burned tokens remain readable, as on the token.
    function textForToken(uint256 tokenId) external view returns (string memory) {
        (, string memory ipfsAddress,,,) = token._property(tokenId);
        return text(ipfsAddress);
    }

    function agreement(string calldata ipfsAddress)
        external
        view
        returns (bytes32 contentHash, uint256 byteLength, address[] memory chunks)
    {
        Agreement storage entry = _agreements[ipfsAddress];
        return (entry.contentHash, entry.byteLength, entry.chunks);
    }

    function _matchesContentAddress(string memory uri, bytes memory data, bytes32 contentHash)
        private
        pure
        returns (bool)
    {
        bytes32 uriHash = keccak256(bytes(uri));
        if (bytes(uri).length == 66) {
            if (
                uriHash
                    == keccak256(abi.encodePacked("ipfs://b", _base32(abi.encodePacked(hex"01551220", contentHash))))
            ) {
                return true;
            }
            return uriHash
                == keccak256(abi.encodePacked("ipfs://b", _base32(abi.encodePacked(hex"01701220", _unixFsHash(data)))));
        }
        if (bytes(uri).length == 53) {
            return
                uriHash
                    == keccak256(abi.encodePacked("ipfs://", _base58(abi.encodePacked(hex"1220", _unixFsHash(data)))));
        }
        return false;
    }

    // UnixFS Data: Type=File, Data=payload, filesize=length. PBNode: Data only.
    function _unixFsHash(bytes memory data) private pure returns (bytes32) {
        bytes memory unixFs = abi.encodePacked(hex"080212", _varint(data.length), data, hex"18", _varint(data.length));
        return sha256(abi.encodePacked(hex"0a", _varint(unixFs.length), unixFs));
    }

    function _varint(uint256 value) private pure returns (bytes memory) {
        uint256 remaining = value;
        uint256 length = 1;
        while (remaining >= 128) {
            ++length;
            remaining >>= 7;
        }
        bytes memory result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            // Only the low 7 bits and the continuation bit are serialized.
            // forge-lint: disable-next-line(unsafe-typecast)
            result[i] = bytes1(uint8(value & 127) | (i + 1 < length ? uint8(128) : uint8(0)));
            value >>= 7;
        }
        return result;
    }

    function _base32(bytes memory value) private pure returns (bytes memory) {
        bytes memory alphabet = "abcdefghijklmnopqrstuvwxyz234567";
        bytes memory result = new bytes((value.length * 8 + 4) / 5);
        uint256 buffer;
        uint256 bits;
        uint256 cursor;
        for (uint256 i; i < value.length; ++i) {
            buffer = (buffer << 8) | uint8(value[i]);
            bits += 8;
            while (bits >= 5) {
                bits -= 5;
                result[cursor++] = alphabet[(buffer >> bits) & 31];
            }
        }
        if (bits != 0) result[cursor] = alphabet[(buffer << (5 - bits)) & 31];
        return result;
    }

    // This private encoder receives exactly 34 nonzero-prefix multihash bytes.
    function _base58(bytes memory value) private pure returns (bytes memory) {
        bytes memory alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        bytes memory digits = new bytes(46);
        uint256 length = 1;
        for (uint256 i; i < value.length; ++i) {
            uint256 carry = uint8(value[i]);
            for (uint256 j; j < length; ++j) {
                carry += uint256(uint8(digits[j])) * 256;
                // A base58 digit is always below 58.
                // forge-lint: disable-next-line(unsafe-typecast)
                digits[j] = bytes1(uint8(carry % 58));
                carry /= 58;
            }
            while (carry != 0) {
                // A base58 digit is always below 58.
                // forge-lint: disable-next-line(unsafe-typecast)
                digits[length++] = bytes1(uint8(carry % 58));
                carry /= 58;
            }
        }
        bytes memory result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[i] = alphabet[uint8(digits[length - 1 - i])];
        }
        return result;
    }
}
