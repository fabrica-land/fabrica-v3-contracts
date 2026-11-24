// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FabricaTrustAgreementRegistry} from "../../src/FabricaTrustAgreementRegistry.sol";

abstract contract TrustAgreementFixtures is Test {
    function _uris() internal pure returns (string[7] memory) {
        return [
            "ipfs://QmXRQx7wPxSwQDVVr1pTkiwvBHBUd1SYLbLgSn1Bvirqpc",
            "ipfs://QmcgEJkgCwizvs6Tu12jCaNMGciRNtH8dLA2TRS3aYWStX",
            "ipfs://QmeRZqhU59Vpn4JQvggBVQ97uMfmS68utweUury8n5JLPR",
            "ipfs://Qmf6Aia6gJfRgGyGroYft3kjxsLUhJEhMYVKPKj2JwY41Z",
            "ipfs://bafkreih72odii5wcwluejt67is5q4zgdqiwqabzkg4pr5vys6o77pgujw4",
            "ipfs://bafkreihepeqissghiwo5zplcywrjlr6bfkgag5jm3jt5szxnsm6kptcpue",
            "ipfs://bafkreihkphcet3ncjlmd7kv4wgc32ot3mnkpudavtydnwt4hdaa3q5z6mi"
        ];
    }

    function _fixture(string memory uri) internal view returns (bytes memory) {
        bytes memory cid = bytes(uri);
        bytes memory name = new bytes(cid.length - 7);
        for (uint256 i; i < name.length; ++i) {
            name[i] = cid[i + 7];
        }
        return vm.readFileBinary(string.concat("test/fixtures/operating-agreements/", string(name), ".txt"));
    }

    function _stage(FabricaTrustAgreementRegistry registry, bytes memory data)
        internal
        returns (address[] memory chunks)
    {
        uint256 chunkSize = registry.MAX_CHUNK_BYTES();
        chunks = new address[]((data.length + chunkSize - 1) / chunkSize);
        for (uint256 i; i < chunks.length; ++i) {
            uint256 offset = i * chunkSize;
            uint256 length = data.length - offset;
            if (length > chunkSize) length = chunkSize;
            bytes memory part = new bytes(length);
            assembly ("memory-safe") {
                mcopy(add(part, 32), add(add(data, 32), offset), length)
            }
            chunks[i] = registry.writeChunk(part);
        }
    }
}
