// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

interface IEng4447PoolFactory {
    function createProxied(address beacon, bytes calldata params) external returns (address);
    function isPool(address pool) external view returns (bool);
}

interface IEng4447Pool {
    function admin() external view returns (address);
    function collateralToken() external view returns (address);
    function currencyToken() external view returns (address);
    function priceOracle() external view returns (address);
    function durations() external view returns (uint64[] memory);
    function rates() external view returns (uint64[] memory);
}

/// @notice Create the ENG-4447 Sepolia pool on the successor eligibility aggregator.
/// @dev Run without --broadcast first. A separate operator approval gates the live transaction.
contract Eng4447CreateSuccessorPoolScript is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;
    address internal constant FACTORY = 0x110bD40421Bf418A8B0d8AbA6568fB020c42Ee83;
    address internal constant BEACON = 0xe1B74Cbf78a693e6289dc1C983D8BC2E5097139e;
    address internal constant OLD_POOL = 0x25dF3D8C3CEBF34a6037b3183f128d8b87275abA;
    address internal constant OLD_ORACLE = 0x54D671dCc9B00b8c4aE40a664370D515A9FC9D9E;
    address internal constant COLLECTION = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    address internal constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant SUCCESSOR = 0xe268C436ffb482c32709ed1e038500429378cA59;
    bytes32 internal constant INITIALIZER_HASH = 0x86afd9493ad7b2bc67b96c4e1faa484de9fcc531d79ed0cb4777459ea91a91a7;

    function run() external returns (address pool) {
        require(block.chainid == SEPOLIA_CHAIN_ID, "ENG-4447: Sepolia only");
        require(FACTORY.code.length > 0 && BEACON.code.length > 0, "ENG-4447: factory or beacon has no code");
        require(SUCCESSOR.code.length > 0, "ENG-4447: successor has no code");
        uint64[] memory expectedDurations = _durations();
        uint64[] memory expectedRates = _rates();
        IEng4447Pool oldPool = IEng4447Pool(OLD_POOL);
        _assertPool(oldPool, FACTORY, OLD_ORACLE, expectedDurations, expectedRates);
        require(oldPool.priceOracle() != SUCCESSOR, "ENG-4447: old pool already uses successor");
        address[] memory collections = new address[](1);
        collections[0] = COLLECTION;
        bytes memory params = abi.encode(collections, USDC, SUCCESSOR, expectedDurations, expectedRates);
        require(keccak256(params) == INITIALIZER_HASH, "ENG-4447: initializer changed");
        vm.startBroadcast();
        pool = IEng4447PoolFactory(FACTORY).createProxied(BEACON, params);
        vm.stopBroadcast();
        require(IEng4447PoolFactory(FACTORY).isPool(pool), "ENG-4447: pool not registered");
        address beaconFromSlot = address(uint160(uint256(vm.load(pool, ERC1967Utils.BEACON_SLOT))));
        require(beaconFromSlot == BEACON, "ENG-4447: beacon mismatch");
        _assertPool(IEng4447Pool(pool), FACTORY, SUCCESSOR, expectedDurations, expectedRates);
        console.log("ENG-4447 simulated pool", pool);
    }

    function _assertPool(
        IEng4447Pool pool,
        address expectedAdmin,
        address expectedOracle,
        uint64[] memory expectedDurations,
        uint64[] memory expectedRates
    ) internal view {
        require(pool.admin() == expectedAdmin, "ENG-4447: admin mismatch");
        require(pool.collateralToken() == COLLECTION, "ENG-4447: collection mismatch");
        require(pool.currencyToken() == USDC, "ENG-4447: currency mismatch");
        require(pool.priceOracle() == expectedOracle, "ENG-4447: oracle mismatch");
        require(
            keccak256(abi.encode(pool.durations())) == keccak256(abi.encode(expectedDurations)),
            "ENG-4447: durations mismatch"
        );
        require(keccak256(abi.encode(pool.rates())) == keccak256(abi.encode(expectedRates)), "ENG-4447: rates mismatch");
    }

    function _durations() internal pure returns (uint64[] memory values) {
        values = new uint64[](8);
        values[0] = 62208000;
        values[1] = 31104000;
        values[2] = 23328000;
        values[3] = 15552000;
        values[4] = 10368000;
        values[5] = 7776000;
        values[6] = 5184000;
        values[7] = 2592000;
    }

    function _rates() internal pure returns (uint64[] memory values) {
        values = new uint64[](8);
        values[0] = 1585489599;
        values[1] = 2219685438;
        values[2] = 3170979198;
        values[3] = 4122272957;
        values[4] = 4756468797;
        values[5] = 5390664637;
        values[6] = 6341958396;
        values[7] = 7927447995;
    }
}
