// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";

// Deploy a new FabricaFeeCollector implementation (ENG-3425, shipping the
// ENG-2547 SafeERC20 + ENG-2548 protocolSharePercent-bound fixes). Runs with
// any wallet: the implementation is immutable, unprivileged, and inert until a
// proxy is pointed at it (the constructor calls _disableInitializers()).
contract FabricaFeeCollectorDeployImplScript is Script {
    function setUp() public {}

    function run(address feeCollectorProxy) public {
        FabricaFeeCollector proxy = FabricaFeeCollector(feeCollectorProxy);
        console.log("Proxy address:", feeCollectorProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Proxy admin:", proxy.proxyAdmin());
        console.log("Owner:", proxy.owner());
        vm.startBroadcast();
        FabricaFeeCollector newImplementation = new FabricaFeeCollector();
        vm.stopBroadcast();
        console.log("New implementation deployed at:", address(newImplementation));
    }
}
