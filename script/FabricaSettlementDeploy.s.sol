// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FabricaSettlement} from "../src/FabricaSettlement.sol";
import {ISettlementPool} from "../src/interfaces/ISettlementPool.sol";

contract FabricaSettlementDeployScript is Script {
    address internal constant CANONICAL_MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    function run() external returns (FabricaSettlement settlement) {
        address seaport = vm.envAddress("SETTLEMENT_SEAPORT");
        address morpho = vm.envAddress("SETTLEMENT_MORPHO");
        address owner = vm.envAddress("SETTLEMENT_OWNER");
        address[] memory initialPools = vm.envAddress("SETTLEMENT_INITIAL_POOLS", ",");
        bool allowNonCanonicalMorpho = vm.envOr("SETTLEMENT_ALLOW_NON_CANONICAL_MORPHO", false);

        require(seaport != address(0), "SETTLEMENT_SEAPORT must not be zero");
        require(morpho != address(0), "SETTLEMENT_MORPHO must not be zero");
        require(owner != address(0), "SETTLEMENT_OWNER must not be zero");
        require(
            morpho == CANONICAL_MORPHO || allowNonCanonicalMorpho,
            "SETTLEMENT_MORPHO is not canonical; set SETTLEMENT_ALLOW_NON_CANONICAL_MORPHO=true to override"
        );
        if (morpho != CANONICAL_MORPHO) {
            console2.log(
                "WARNING: deploying against a NON-CANONICAL Morpho",
                morpho,
                "-- must be a verified ZERO-FEE provider or every settlement reverts"
            );
        }
        for (uint256 i; i < initialPools.length; ++i) {
            require(initialPools[i] != address(0), "SETTLEMENT_INITIAL_POOLS contains zero");
        }

        console2.log("Seaport:", seaport);
        console2.log("Morpho:", morpho);
        console2.log("Owner:", owner);
        console2.log("Initial pool count:", initialPools.length);
        for (uint256 i; i < initialPools.length; ++i) {
            console2.log("Initial pool:", initialPools[i]);
            address currency = ISettlementPool(initialPools[i]).currencyToken();
            console2.log("  Currency token:", currency);
            console2.log("  Currency decimals:", IERC20Metadata(currency).decimals());
        }

        vm.startBroadcast();
        settlement = new FabricaSettlement(seaport, morpho, owner, initialPools);
        vm.stopBroadcast();
        console2.log("FabricaSettlement deployed at:", address(settlement));
    }
}
