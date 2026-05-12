// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "../lib/openzeppelin-contracts-v4/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {PoolFactory} from "../src/fabrica-lending-pools/PoolFactory.sol";
import {ERC1155CollateralWrapper} from "../src/fabrica-lending-pools/wrappers/ERC1155CollateralWrapper.sol";
import {EnglishAuctionCollateralLiquidator} from "../src/fabrica-lending-pools/liquidators/EnglishAuctionCollateralLiquidator.sol";
import {SimpleSignedPriceOracle} from "../src/fabrica-lending-pools/oracle/SimpleSignedPriceOracle.sol";
import {ERC20DepositTokenImplementation} from "../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";
import {WeightedRateERC1155CollectionPool} from "../src/fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol";

/**
 * @title Fabrica Lending Pool stack deployment (one-shot)
 *
 * Deploys all reusable infrastructure for a Fabrica Lending Pool
 * deployment on a new chain. Mirrors the topology + on-chain parameters
 * of the live mainnet pool at 0x842ffbf1ad5314503904626122376f71603a3cf9
 * (IMPLEMENTATION_VERSION 2.15). Pool instances are created separately
 * via FabricaLendingPoolCreate.s.sol against this infra.
 *
 * Required env:
 *   FABRICA_LENDING_DELEGATE_REGISTRY_V1   delegate.xyz v1 canonical address
 *   FABRICA_LENDING_DELEGATE_REGISTRY_V2   delegate.xyz v2 canonical address
 *   FABRICA_LENDING_ORACLE_DOMAIN_NAME     EIP-712 domain name (e.g. "All Fabrica Properties")
 *
 * Optional env (defaults mirror mainnet):
 *   FABRICA_LENDING_AUCTION_DURATION       uint64 seconds; default 86400
 *   FABRICA_LENDING_AUCTION_EXT_WINDOW     uint64 seconds; default 600
 *   FABRICA_LENDING_AUCTION_EXT            uint64 seconds; default 900
 *   FABRICA_LENDING_AUCTION_MIN_BID_BPS    uint64 basis points; default 200
 */
contract FabricaLendingPoolStackDeployScript is Script {
    function setUp() public {}

    function run() public {
        address delegateV1 = vm.envAddress("FABRICA_LENDING_DELEGATE_REGISTRY_V1");
        address delegateV2 = vm.envAddress("FABRICA_LENDING_DELEGATE_REGISTRY_V2");
        string memory oracleName = vm.envString("FABRICA_LENDING_ORACLE_DOMAIN_NAME");
        uint64 auctionDuration = uint64(vm.envOr("FABRICA_LENDING_AUCTION_DURATION", uint256(86400)));
        uint64 auctionExtWindow = uint64(vm.envOr("FABRICA_LENDING_AUCTION_EXT_WINDOW", uint256(600)));
        uint64 auctionExt = uint64(vm.envOr("FABRICA_LENDING_AUCTION_EXT", uint256(900)));
        uint64 auctionMinBidBps = uint64(vm.envOr("FABRICA_LENDING_AUCTION_MIN_BID_BPS", uint256(200)));
        console.log("Delegate registry v1:", delegateV1);
        console.log("Delegate registry v2:", delegateV2);
        console.log("Oracle domain name:", oracleName);
        vm.startBroadcast();
        ERC20DepositTokenImplementation depositTokenImpl = new ERC20DepositTokenImplementation();
        ERC1155CollateralWrapper wrapper = new ERC1155CollateralWrapper();
        address[] memory wrappersList = new address[](1);
        wrappersList[0] = address(wrapper);
        EnglishAuctionCollateralLiquidator liquidatorImpl = new EnglishAuctionCollateralLiquidator(wrappersList);
        bytes memory liquidatorInit = abi.encodeCall(
            EnglishAuctionCollateralLiquidator.initialize,
            (auctionDuration, auctionExtWindow, auctionExt, auctionMinBidBps)
        );
        ERC1967Proxy liquidatorProxy = new ERC1967Proxy(address(liquidatorImpl), liquidatorInit);
        SimpleSignedPriceOracle oracleImpl = new SimpleSignedPriceOracle(oracleName);
        bytes memory oracleInit = abi.encodeCall(SimpleSignedPriceOracle.initialize, (msg.sender));
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(oracleImpl), oracleInit);
        PoolFactory factoryImpl = new PoolFactory();
        bytes memory factoryInit = abi.encodeWithSelector(PoolFactory.initialize.selector);
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        WeightedRateERC1155CollectionPool poolImpl = new WeightedRateERC1155CollectionPool(
            address(liquidatorProxy),
            delegateV1,
            delegateV2,
            address(depositTokenImpl),
            wrappersList
        );
        UpgradeableBeacon beacon = new UpgradeableBeacon(address(poolImpl));
        PoolFactory(address(factoryProxy)).addPoolImplementation(address(beacon));
        vm.stopBroadcast();
        console.log("=== Fabrica Lending Pool stack deployed ===");
        console.log("ERC20DepositTokenImplementation:    ", address(depositTokenImpl));
        console.log("ERC1155CollateralWrapper:           ", address(wrapper));
        console.log("EnglishAuctionLiquidator impl:      ", address(liquidatorImpl));
        console.log("EnglishAuctionLiquidator (proxy):   ", address(liquidatorProxy));
        console.log("SimpleSignedPriceOracle impl:       ", address(oracleImpl));
        console.log("SimpleSignedPriceOracle (proxy):    ", address(oracleProxy));
        console.log("PoolFactory impl:                   ", address(factoryImpl));
        console.log("PoolFactory (proxy):                ", address(factoryProxy));
        console.log("WeightedRateERC1155CollectionPool impl:", address(poolImpl));
        console.log("UpgradeableBeacon:                  ", address(beacon));
        console.log("Beacon registered with factory:     true");
        console.log("Oracle owner / factory owner:       ", msg.sender);
    }
}
