// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {FabricaTrustAgreementRegistry} from "../src/FabricaTrustAgreementRegistry.sol";

/// @notice Deploy only. The signer comes from Forge, never from a script env key.
contract FabricaTrustAgreementRegistryDeployScript is Script {
    function run(address tokenContract) external returns (FabricaTrustAgreementRegistry registry) {
        vm.startBroadcast();
        registry = new FabricaTrustAgreementRegistry(tokenContract);
        vm.stopBroadcast();
        console2.log("FabricaTrustAgreementRegistry:", address(registry));
        console2.log("Token:", address(registry.token()));
    }
}
