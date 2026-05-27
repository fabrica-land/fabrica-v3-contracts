// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";

import {UpgradeableBeacon} from "../lib/openzeppelin-contracts-v4/contracts/proxy/beacon/UpgradeableBeacon.sol";

interface IWeightedRateERC1155CollectionPoolView {
    function IMPLEMENTATION_NAME() external pure returns (string memory);
    function IMPLEMENTATION_VERSION() external pure returns (string memory);
}

/**
 * @title Fabrica Lending Pool beacon upgrade (deploy new impl + repoint beacon)
 *
 * One-shot upgrade of every Fabrica-deployed `BeaconProxy` lending pool
 * tied to the named beacon. Two distinct on-chain operations, batched
 * into one script because both must be run by the beacon owner and the
 * deploy → repoint sequence is invariant:
 *
 *   1. Deploy a new `WeightedRateERC1155CollectionPool` implementation
 *      with the same constructor immutables as the current one.
 *   2. Call `beacon.upgradeTo(newImpl)` on the existing beacon. Every
 *      `BeaconProxy` pool created against this beacon picks up the
 *      new code at its next call. No liquidity moves; no pool
 *      addresses change.
 *
 * Sibling scripts and when to use which:
 *
 *   - `FabricaLendingPoolStackDeploy.s.sol`  — stand up a NEW lending
 *      pool stack on a fresh chain (or a fresh liquidity-isolation
 *      domain on an existing chain). Use when no beacon exists yet.
 *      Use this script instead when upgrading the impl that an
 *      existing beacon already references.
 *   - `FabricaLendingPoolCreate.s.sol`       — spawn a new BeaconProxy
 *      pool instance against an existing stack (different collateral
 *      token, different currency token, etc).
 *
 * Required env (pulled off the live pool — see LENDING-POOL-RUNBOOK.md):
 *   FABRICA_LENDING_BEACON                       UpgradeableBeacon address
 *   FABRICA_LENDING_COLLATERAL_LIQUIDATOR        Auction-based liquidator proxy
 *   FABRICA_LENDING_DELEGATE_REGISTRY_V1         delegate.xyz V1 canonical
 *   FABRICA_LENDING_DELEGATE_REGISTRY_V2         delegate.xyz V2 canonical
 *   FABRICA_LENDING_ERC20_DEPOSIT_TOKEN_IMPL     ERC20DepositTokenImplementation
 *   FABRICA_LENDING_ERC1155_COLLATERAL_WRAPPER   ERC1155CollateralWrapper
 *
 * Constructor immutables MUST match the current beacon target —
 * `WeightedRateERC1155CollectionPool` stores `_collateralLiquidator`,
 * `_delegateRegistryV1`, `_delegateRegistryV2`, `_collateralWrapper{1,2,3}`,
 * and `_erc20DepositTokenImpl` as bytecode immutables. Re-using the same
 * values guarantees that every existing BeaconProxy pool continues to
 * see the same dependency contracts post-upgrade. The runbook documents
 * the `cast call` queries that read these off the live pool.
 *
 * Deployment (per CLAUDE.md — always include `--verify`):
 *   forge script script/FabricaLendingPoolUpgrade.s.sol:FabricaLendingPoolUpgradeScript \
 *     --rpc-url $RPC_URL --broadcast --verify
 * If verification fails during the broadcast, follow up afterward with:
 *   forge verify-contract <new_impl_address> \
 *     src/fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol:WeightedRateERC1155CollectionPool \
 *     --chain <chain_id>
 */
contract FabricaLendingPoolUpgradeScript is Script {
    function setUp() public {}

    function run() public {
        address beaconAddr = vm.envAddress("FABRICA_LENDING_BEACON");
        address collateralLiquidator = vm.envAddress("FABRICA_LENDING_COLLATERAL_LIQUIDATOR");
        address delegateV1 = vm.envAddress("FABRICA_LENDING_DELEGATE_REGISTRY_V1");
        address delegateV2 = vm.envAddress("FABRICA_LENDING_DELEGATE_REGISTRY_V2");
        address erc20DepositTokenImpl = vm.envAddress("FABRICA_LENDING_ERC20_DEPOSIT_TOKEN_IMPL");
        address erc1155CollateralWrapper = vm.envAddress("FABRICA_LENDING_ERC1155_COLLATERAL_WRAPPER");

        UpgradeableBeacon beacon = UpgradeableBeacon(beaconAddr);
        address currentImpl = beacon.implementation();
        address beaconOwner = beacon.owner();

        console.log("Beacon:                    ", beaconAddr);
        console.log("Beacon owner:              ", beaconOwner);
        console.log("Current implementation:    ", currentImpl);
        console.log("Collateral liquidator:     ", collateralLiquidator);
        console.log("Delegate registry V1:      ", delegateV1);
        console.log("Delegate registry V2:      ", delegateV2);
        console.log("ERC20 deposit token impl:  ", erc20DepositTokenImpl);
        console.log("ERC1155 collateral wrapper:", erc1155CollateralWrapper);

        address[] memory wrappersList = new address[](1);
        wrappersList[0] = erc1155CollateralWrapper;

        // Deploy via vm.deployCode (reads the precompiled artifact + handles
        // library linking) instead of `new WeightedRateERC1155CollectionPool`.
        // Direct Solidity instantiation here would add a second `new` call
        // site to the project's via_ir compilation graph (alongside
        // FabricaLendingPoolStackDeploy.s.sol's), which perturbs the
        // whole-program inliner and pushes the pool's runtime bytecode ~1.4 KB
        // over EIP-170. Reading the artifact at runtime keeps the
        // compilation graph identical to the stack-deploy-only case.
        bytes memory constructorArgs =
            abi.encode(collateralLiquidator, delegateV1, delegateV2, erc20DepositTokenImpl, wrappersList);
        vm.startBroadcast();
        address newImpl =
            vm.deployCode("WeightedRateERC1155CollectionPool.sol:WeightedRateERC1155CollectionPool", constructorArgs);
        require(newImpl != currentImpl, "no-op upgrade");
        beacon.upgradeTo(newImpl);
        vm.stopBroadcast();

        address postImpl = beacon.implementation();
        console.log("=== Beacon upgraded ===");
        console.log("New WeightedRateERC1155CollectionPool:", newImpl);
        console.log(
            "IMPLEMENTATION_NAME:                  ",
            IWeightedRateERC1155CollectionPoolView(newImpl).IMPLEMENTATION_NAME()
        );
        console.log(
            "IMPLEMENTATION_VERSION:               ",
            IWeightedRateERC1155CollectionPoolView(newImpl).IMPLEMENTATION_VERSION()
        );
        console.log("Verified beacon.implementation():     ", postImpl);
        require(postImpl == newImpl, "upgrade verification failed");
    }
}
