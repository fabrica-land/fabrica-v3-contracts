// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {UpgradeableBeacon} from "../lib/openzeppelin-contracts-v4/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {IPool} from "../src/fabrica-lending-pools/interfaces/IPool.sol";

/**
 * @title Fabrica Lending Pool beacon upgrade
 *
 * Points the existing `UpgradeableBeacon` (the one all Fabrica-deployed
 * `BeaconProxy` pool instances delegate-call through) at a new
 * `WeightedRateERC1155CollectionPool` implementation. Atomically upgrades
 * every BeaconProxy pool created against that beacon — no liquidity is
 * moved, no pool addresses change, depositors and borrowers see the new
 * code at the next call.
 *
 * Must be run by the beacon's owner — the same wallet that deployed the
 * stack via `FabricaLendingPoolStackDeploy.s.sol`. Deploy the new impl
 * first via `FabricaLendingPoolDeployImpl.s.sol`, then pass the resulting
 * address as the `newImplementation` argument here.
 *
 * Sepolia state (recorded for the ENG-3076 upgrade):
 *   Beacon:          0xe1b74cbf78a693E6289dC1c983D8bC2e5097139E
 *   Beacon owner:    0xBF03076547a99857b796717faF4034dea94569dF
 *   Factory:         0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83
 *   Pool (BeaconProxy, currency=USDC, collateral=FabricaToken):
 *                    0x6C56d0953377D7AB479BBA85Da8d61050F774c0B
 *
 * Deployment (per CLAUDE.md — always include `--verify` where applicable;
 * this script only calls `upgradeTo` on an existing contract, no new
 * deploy, so `--verify` is a no-op but harmless):
 *   forge script script/FabricaLendingPoolUpgrade.s.sol:FabricaLendingPoolUpgradeScript \
 *     --sig 'run(address,address)' <beacon> <newImplementation> \
 *     --rpc-url $RPC_URL --broadcast
 */
contract FabricaLendingPoolUpgradeScript is Script {
    function setUp() public {}

    function run(address beacon, address newImplementation) public {
        UpgradeableBeacon b = UpgradeableBeacon(beacon);
        address currentImpl = b.implementation();
        address beaconOwner = b.owner();

        console.log("Beacon:                  ", beacon);
        console.log("Beacon owner:            ", beaconOwner);
        console.log("Current implementation:  ", currentImpl);
        console.log("Upgrading to:            ", newImplementation);
        require(currentImpl != newImplementation, "no-op upgrade");

        vm.startBroadcast();
        b.upgradeTo(newImplementation);
        vm.stopBroadcast();

        address postImpl = b.implementation();
        console.log("=== Beacon upgraded ===");
        console.log("Verified implementation:", postImpl);
        require(postImpl == newImplementation, "upgrade verification failed");
    }
}
