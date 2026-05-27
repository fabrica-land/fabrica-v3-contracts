// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "../lib/openzeppelin-contracts-v4/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {PoolFactory} from "../src/fabrica-lending-pools/PoolFactory.sol";
import {ERC1155CollateralWrapper} from "../src/fabrica-lending-pools/wrappers/ERC1155CollateralWrapper.sol";
import {
    EnglishAuctionCollateralLiquidator
} from "../src/fabrica-lending-pools/liquidators/EnglishAuctionCollateralLiquidator.sol";
import {SimpleSignedPriceOracle} from "../src/fabrica-lending-pools/oracle/SimpleSignedPriceOracle.sol";
import {
    ERC20DepositTokenImplementation
} from "../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";
import {
    WeightedRateERC1155CollectionPool
} from "../src/fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol";

/**
 * @title Fabrica Lending Pool stack deployment (one-shot) + impl-only deploy
 *
 * `run()` deploys all reusable infrastructure for a Fabrica Lending Pool
 * stack on a new chain (oracle, liquidator, factory, deposit token impl,
 * ERC1155 wrapper, pool impl, beacon). Pool instances are created
 * separately via FabricaLendingPoolCreate.s.sol against this infra.
 *
 * `runImplOnly()` deploys ONLY a new WeightedRateERC1155CollectionPool
 * implementation against a chain that already has the rest of the stack
 * — used by the beacon-upgrade flow in `FabricaLendingPoolUpgrade.s.sol`.
 * It deliberately lives in this script (not a separate file) because the
 * pool `new` site has to share one compilation unit with the stack
 * deploy's `new` site — splitting it across two script files perturbs
 * the via_ir whole-program inliner and pushes the pool's runtime
 * bytecode ~1.4 KB over EIP-170. Keep this co-located.
 *
 * Mirrors the topology + on-chain parameters of the live mainnet pool
 * at 0x842ffbf1ad5314503904626122376f71603a3cf9 (IMPLEMENTATION_VERSION
 * 2.15).
 *
 * Required env for `run()` (full stack):
 *   FABRICA_LENDING_DELEGATE_REGISTRY_V1   delegate.xyz v1 canonical address
 *   FABRICA_LENDING_DELEGATE_REGISTRY_V2   delegate.xyz v2 canonical address
 *   FABRICA_LENDING_ORACLE_DOMAIN_NAME     EIP-712 domain name (e.g. "All Fabrica Properties")
 *   FABRICA_LENDING_OWNER                  address that owns the deployed oracle + factory
 *                                          (must equal the broadcaster). Required explicitly to
 *                                          avoid silently inheriting Foundry's default sender
 *                                          (0x1804…) when `forge script` runs without a
 *                                          configured signer.
 *
 * Optional env for `run()` (defaults mirror mainnet):
 *   FABRICA_LENDING_AUCTION_DURATION       uint64 seconds; default 86400
 *   FABRICA_LENDING_AUCTION_EXT_WINDOW     uint64 seconds; default 600
 *   FABRICA_LENDING_AUCTION_EXT            uint64 seconds; default 900
 *   FABRICA_LENDING_AUCTION_MIN_BID_BPS    uint64 basis points; default 200
 *
 * Required env for `runImplOnly()` (pulled off the existing live pool —
 * see LENDING-POOL-RUNBOOK.md for the cast queries):
 *   FABRICA_LENDING_COLLATERAL_LIQUIDATOR    Auction-based liquidator proxy
 *   FABRICA_LENDING_DELEGATE_REGISTRY_V1     delegate.xyz V1 canonical
 *   FABRICA_LENDING_DELEGATE_REGISTRY_V2     delegate.xyz V2 canonical
 *   FABRICA_LENDING_ERC20_DEPOSIT_TOKEN_IMPL ERC20DepositTokenImplementation
 *   FABRICA_LENDING_ERC1155_COLLATERAL_WRAPPER ERC1155CollateralWrapper
 *
 * Deployment (per CLAUDE.md — always include `--verify`):
 *   forge script script/FabricaLendingPoolStackDeploy.s.sol:FabricaLendingPoolStackDeployScript \
 *     --sig 'runImplOnly()' \
 *     --rpc-url $RPC_URL --broadcast --verify
 * If verification fails during the broadcast, follow up afterward with:
 *   forge verify-contract <deployed_address> \
 *     src/fabrica-lending-pools/configurations/WeightedRateERC1155CollectionPool.sol:WeightedRateERC1155CollectionPool \
 *     --chain <chain_id>
 */
contract FabricaLendingPoolStackDeployScript is Script {
    function setUp() public {}

    function run() public {
        address delegateV1 = vm.envAddress("FABRICA_LENDING_DELEGATE_REGISTRY_V1");
        address delegateV2 = vm.envAddress("FABRICA_LENDING_DELEGATE_REGISTRY_V2");
        string memory oracleName = vm.envString("FABRICA_LENDING_ORACLE_DOMAIN_NAME");
        address owner = vm.envAddress("FABRICA_LENDING_OWNER");
        require(owner == msg.sender, "FABRICA_LENDING_OWNER must equal broadcaster");
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
        bytes memory oracleInit = abi.encodeCall(SimpleSignedPriceOracle.initialize, (owner));
        ERC1967Proxy oracleProxy = new ERC1967Proxy(address(oracleImpl), oracleInit);
        PoolFactory factoryImpl = new PoolFactory();
        bytes memory factoryInit = abi.encodeWithSelector(PoolFactory.initialize.selector);
        ERC1967Proxy factoryProxy = new ERC1967Proxy(address(factoryImpl), factoryInit);
        WeightedRateERC1155CollectionPool poolImpl =
            _deployPoolImpl(address(liquidatorProxy), delegateV1, delegateV2, address(depositTokenImpl), wrappersList);
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
        console.log("Oracle owner / factory owner:       ", owner);
    }

    /// @notice Deploy ONLY a new pool implementation (used by the beacon-upgrade flow).
    /// All other stack components (liquidator, oracle, factory, beacon, wrapper, deposit
    /// token impl) must already exist on-chain; pass their addresses through env.
    function runImplOnly() public {
        address collateralLiquidator = vm.envAddress("FABRICA_LENDING_COLLATERAL_LIQUIDATOR");
        address delegateV1 = vm.envAddress("FABRICA_LENDING_DELEGATE_REGISTRY_V1");
        address delegateV2 = vm.envAddress("FABRICA_LENDING_DELEGATE_REGISTRY_V2");
        address erc20DepositTokenImpl = vm.envAddress("FABRICA_LENDING_ERC20_DEPOSIT_TOKEN_IMPL");
        address erc1155CollateralWrapper = vm.envAddress("FABRICA_LENDING_ERC1155_COLLATERAL_WRAPPER");

        address[] memory wrappersList = new address[](1);
        wrappersList[0] = erc1155CollateralWrapper;

        console.log("Collateral liquidator:     ", collateralLiquidator);
        console.log("Delegate registry V1:      ", delegateV1);
        console.log("Delegate registry V2:      ", delegateV2);
        console.log("ERC20 deposit token impl:  ", erc20DepositTokenImpl);
        console.log("ERC1155 collateral wrapper:", erc1155CollateralWrapper);

        vm.startBroadcast();
        WeightedRateERC1155CollectionPool poolImpl =
            _deployPoolImpl(collateralLiquidator, delegateV1, delegateV2, erc20DepositTokenImpl, wrappersList);
        vm.stopBroadcast();

        console.log("=== Pool implementation deployed ===");
        console.log("New WeightedRateERC1155CollectionPool:", address(poolImpl));
        console.log("IMPLEMENTATION_NAME:                  ", poolImpl.IMPLEMENTATION_NAME());
        console.log("IMPLEMENTATION_VERSION:               ", poolImpl.IMPLEMENTATION_VERSION());
    }

    /// @dev Single `new WeightedRateERC1155CollectionPool` instantiation site for
    /// both run() and runImplOnly() — splitting this across two call sites or
    /// two script files perturbs via_ir's whole-program inliner and pushes the
    /// pool's runtime bytecode over EIP-170. Keep it private + single-callsite.
    function _deployPoolImpl(
        address liquidator,
        address delegateV1,
        address delegateV2,
        address erc20DepositTokenImpl,
        address[] memory wrappersList
    ) private returns (WeightedRateERC1155CollectionPool) {
        return new WeightedRateERC1155CollectionPool(
            liquidator, delegateV1, delegateV2, erc20DepositTokenImpl, wrappersList
        );
    }
}
