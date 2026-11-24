// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {FabricaTrustAgreementRegistry} from "../src/FabricaTrustAgreementRegistry.sol";

/// @notice Load exactly one file per operation, independently of deployment.
contract FabricaTrustAgreementRegistryLoadScript is Script {
    function run(address registryAddress, string calldata ipfsAddress, string calldata filePath) external {
        bytes memory data = vm.readFileBinary(filePath);
        FabricaTrustAgreementRegistry registry = FabricaTrustAgreementRegistry(registryAddress);
        vm.startBroadcast();
        uint256 chunkSize = registry.MAX_CHUNK_BYTES();
        address[] memory chunks = new address[]((data.length + chunkSize - 1) / chunkSize);
        for (uint256 i; i < chunks.length; ++i) {
            uint256 offset = i * chunkSize;
            uint256 length = data.length - offset;
            if (length > chunkSize) length = chunkSize;
            bytes memory chunk = new bytes(length);
            assembly ("memory-safe") {
                mcopy(add(chunk, 32), add(add(data, 32), offset), length)
            }
            chunks[i] = registry.writeChunk(chunk);
        }
        registry.store(ipfsAddress, chunks);
        vm.stopBroadcast();
        require(keccak256(bytes(registry.text(ipfsAddress))) == keccak256(data), "readback mismatch");
        console2.log("Agreement:", ipfsAddress);
        console2.log("Bytes:", data.length);
        console2.logBytes32(sha256(data));
    }
}
