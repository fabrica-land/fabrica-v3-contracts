// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";

// Upgrade a FabricaFeeCollector proxy to a new implementation (ENG-3425).
// Runs with the proxy admin wallet. Empty upgrade data: the ENG-2547/2548 fix
// changes no storage layout and adds no reinitializer, and the currently
// deployed implementations are already OZ v5 (whose upgradeToAndCall skips the
// delegatecall when data is empty), so no initializer must run during upgrade.
contract FabricaFeeCollectorUpgradeScript is Script {
    function setUp() public {}

    function run(address feeCollectorProxy, address newImplementation) public {
        FabricaFeeCollector proxy = FabricaFeeCollector(feeCollectorProxy);
        console.log("Proxy address:", feeCollectorProxy);
        console.log("Current implementation:", proxy.implementation());
        console.log("Upgrading to:", newImplementation);
        vm.startBroadcast();
        proxy.upgradeToAndCall(newImplementation, "");
        vm.stopBroadcast();
        _logState(proxy);
    }

    function _logState(FabricaFeeCollector proxy) internal view {
        console.log("Proxy upgraded");
        console.log("Verified implementation:", proxy.implementation());
        console.log("Proxy admin:", proxy.proxyAdmin());
        console.log("Owner:", proxy.owner());
        console.log("protocolSharePercent:", proxy.protocolSharePercent());
        console.log("protocolContractAddress:", proxy.protocolContractAddress());
        console.log("protocolFeeRecipient:", proxy.protocolFeeRecipient());
    }
}
