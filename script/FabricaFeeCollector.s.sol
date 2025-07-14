// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";
import {FabricaProxy} from "../src/FabricaProxy.sol";

contract FabricaFeeCollectorScript is Script {
    function setUp() public {}

    function run(
      address protocolContract,
      uint8 protocolSharePercent,
      address protocolFeeRecipient,
      address proxyAdmin,
      address owner
    ) public {
      vm.startBroadcast();
      FabricaFeeCollector implementation = new FabricaFeeCollector();
      bytes memory initializeData = abi.encodeWithSignature(
        "initialize(address,uint8,address)",
        protocolContract,
        protocolSharePercent,
        protocolFeeRecipient
      );
      FabricaProxy proxy = new FabricaProxy(
        address(implementation),
        proxyAdmin,
        initializeData
      );
      FabricaFeeCollector(address(proxy)).transferOwnership(owner);
      console.log("FabricaFeeCollector deployed at:", address(proxy));
      vm.stopBroadcast();
    }
}
