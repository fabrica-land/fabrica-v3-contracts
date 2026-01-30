// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaValidator} from "../src/FabricaValidator.sol";

contract FabricaValidatorSetDefaultOAScript is Script {
    function setUp() public {}

    function run(address validatorProxy, string calldata uri, string calldata name) public {
        FabricaValidator validator = FabricaValidator(validatorProxy);
        console.log("FabricaValidator proxy:", validatorProxy);
        console.log("Current default OA:", validator.defaultOperatingAgreement());
        string memory existingName = validator.operatingAgreementName(uri);
        vm.startBroadcast();
        if (bytes(existingName).length == 0) {
            validator.addOperatingAgreementName(uri, name);
            console.log("Added operating agreement name:", name);
        } else {
            console.log("Operating agreement name already set:", existingName);
        }
        validator.setDefaultOperatingAgreement(uri);
        console.log("Set default operating agreement to:", uri);
        vm.stopBroadcast();
    }
}
