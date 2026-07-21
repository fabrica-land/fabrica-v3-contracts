// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaMarketplaceZone} from "../src/FabricaMarketplaceZone.sol";

contract FabricaSettlementMainnetForkTest is Test {
    address internal constant SEAPORT_1_6 = 0x0000000000000068F116a894984e2DB1123eB395;
    uint256 internal constant MAINNET_FORK_BLOCK = 25_238_609;

    function testFork_canonicalSeaportAndLocalZone() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", MAINNET_FORK_BLOCK);
        assertGt(SEAPORT_1_6.code.length, 0, "canonical Seaport missing");
        FabricaMarketplaceZone zone = new FabricaMarketplaceZone(vm.addr(0xA11CE));
        assertEq(zone.oracleSigner(), vm.addr(0xA11CE));
    }
}
