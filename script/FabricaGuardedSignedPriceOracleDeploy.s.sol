// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FabricaGuardedSignedPriceOracle} from "../src/FabricaGuardedSignedPriceOracle.sol";

contract FabricaGuardedSignedPriceOracleDeployScript is Script {
    function run() external returns (FabricaGuardedSignedPriceOracle oracle) {
        address owner = vm.envAddress("GUARDED_ORACLE_OWNER");
        string memory name = vm.envString("GUARDED_ORACLE_NAME");
        require(owner != address(0), "GUARDED_ORACLE_OWNER must not be zero");
        require(bytes(name).length != 0, "GUARDED_ORACLE_NAME must not be empty");
        console2.log("Oracle owner:", owner);
        console2.log("Oracle EIP712 name:", name);
        vm.startBroadcast();
        FabricaGuardedSignedPriceOracle implementation = new FabricaGuardedSignedPriceOracle();
        bytes memory initData = abi.encodeCall(FabricaGuardedSignedPriceOracle.initialize, (owner, name));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vm.stopBroadcast();
        oracle = FabricaGuardedSignedPriceOracle(address(proxy));
        console2.log("FabricaGuardedSignedPriceOracle implementation:", address(implementation));
        console2.log("FabricaGuardedSignedPriceOracle proxy:", address(proxy));
        console2.log("Initialized owner:", oracle.owner());
    }
}
