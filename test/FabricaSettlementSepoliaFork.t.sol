// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

/// @notice Real-integration scaffold for Fabrica settlement against the deployed Sepolia stack.
/// @dev Both paths remain skipped until an active loan receipt and oracle-signed zone orders are available.
contract FabricaSettlementSepoliaForkTest is Test {
    address internal constant SEAPORT_1_6 = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant FORK_POOL = 0x6C56d0953377D7AB479BBA85Da8d61050F774c0B;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc);
        assertEq(block.chainid, 11155111, "SEPOLIA_RPC_URL must target Sepolia");
        assertGt(SEAPORT_1_6.code.length, 0, "Seaport 1.6 missing");
        assertGt(MORPHO.code.length, 0, "Morpho missing");
        assertGt(FORK_POOL.code.length, 0, "Fabrica fork pool missing");
    }

    function testFork_shapeA_priceHeadroom_happyPath() public {
        // TODO(ENG-3506): source an active FORK_POOL loan receipt whose collateral has a valid
        // oracle-signed Seaport zone order with the payoff removed from the seller floor.
        vm.skip(true);
    }

    function testFork_shapeB_sellerAllowance_happyPath() public {
        // TODO(ENG-3506): source an active FORK_POOL loan receipt, a full-price oracle-signed
        // Seaport zone order, borrower allowance, and buyer/payer funding fixtures.
        vm.skip(true);
    }
}
