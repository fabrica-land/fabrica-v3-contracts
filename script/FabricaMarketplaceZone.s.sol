// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaMarketplaceZone} from "../src/FabricaMarketplaceZone.sol";

contract FabricaMarketplaceZoneScript is Script {
    FabricaMarketplaceZone public fabricaMarketplaceZone;

    function setUp() public {}

    function run(address oracleSigner) public {
      vm.startBroadcast();
      fabricaMarketplaceZone = new FabricaMarketplaceZone(oracleSigner);
      console.log("FabricaMarketplaceZone deployed at:", address(fabricaMarketplaceZone));
      vm.stopBroadcast();
    }
}
