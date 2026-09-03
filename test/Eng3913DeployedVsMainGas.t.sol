// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {FabricaAttributeOracle} from "../src/FabricaAttributeOracle.sol";
import {DeployedRound1FactStore} from "../bench/oracle-gas-model/deployed-round1/DeployedRound1FactStore.sol";

/// @notice ENG-3913: the same four `writePrice` regimes measured against BOTH the code on
///         `main` and the code actually deployed on Sepolia, under one harness.
/// @dev Why this exists, and what it actually found. `main` is NOT the code deployed for
///      round 1: the deployed store is commit `062f049`, and `main` moved afterwards at
///      `10aafd6` (ENG-3523, 2026-09-01), which refactored `_writePrice`. The hypothesis
///      under test was that this explained a gap against ENG-3922's fork measurements of
///      the live contract.
///
///      IT DID NOT. Measured here with identical priming and instrumentation, the deployed
///      code is 311-657 gas CHEAPER than `main` (0.4-0.9%), which is both small and in the
///      opposite direction to the gap. The real cause of that gap was a defect in this
///      bench's own provenance handling, fixed separately: constant `rawPayloadHash` /
///      `inputsHash` made two storage words no-op writes. After that fix three of the four
///      regimes agree with ENG-3922 to 0.2%; the write-1 residual remains unresolved.
///
///      This test is kept because the deployed-versus-`main` delta is worth knowing on its
///      own, and because a killed hypothesis should leave an artifact rather than a memory.
///
///      Method is the same as `Eng3913OracleGasBench`: one scenario per test, priming in
///      `setUp`, a codeless control for the CALL overhead, `vm.cool` before each
///      measurement. See that file's header for why each of those matters.
contract Eng3913DeployedVsMainGas is Test {
    FabricaAttributeOracle internal mainStore;
    DeployedRound1FactStore internal deployedStore;
    address internal noop;
    address internal owner;
    address internal publisher;

    uint8 internal constant SRC = 0;
    uint128 internal constant PRICE = 100_000e6;
    uint128 internal constant PRICE_MOVED = 104_000e6;
    uint256 internal constant TOKEN = 4_242_424;

    uint256 internal constant V_FIRST = 1;
    uint256 internal constant V_SECOND = 2;
    uint256 internal constant V_MID = 3;
    uint256 internal constant V_WRAPPED = 4;

    function setUp() public {
        vm.warp(1_700_000_000);
        owner = makeAddr("owner");
        publisher = makeAddr("publisher");
        noop = makeAddr("callOverheadControl");

        FabricaAttributeOracle mainBootstrap = new FabricaAttributeOracle(owner, _knobs());
        mainStore = new FabricaAttributeOracle(owner, mainBootstrap.defaultKnobs());
        DeployedRound1FactStore deployedBootstrap = new DeployedRound1FactStore(owner, _deployedKnobs());
        deployedStore = new DeployedRound1FactStore(owner, deployedBootstrap.defaultKnobs());
        // Both stores must be configured identically or the comparison is worthless.
        assertEq(mainStore.historyDepth(), deployedStore.historyDepth(), "historyDepth differs");
        assertEq(mainStore.minWriteInterval(), deployedStore.minWriteInterval(), "minWriteInterval differs");
        assertEq(mainStore.maxUpBps(), deployedStore.maxUpBps(), "maxUpBps differs");

        _prime(address(mainStore));
        _prime(address(deployedStore));
    }

    // Both contracts share this ABI shape, so one calldata builder drives both.
    function _prime(address store) internal {
        vm.startPrank(owner);
        uint256[4] memory vs = [V_FIRST, V_SECOND, V_MID, V_WRAPPED];
        for (uint256 i; i < vs.length; ++i) {
            _call(store, abi.encodeWithSignature("setPricePublisher(uint256,address,bool)", vs[i], publisher, true));
            _call(store, abi.encodeWithSignature("register(uint256,uint256)", vs[i], TOKEN));
        }
        _call(store, abi.encodeWithSignature("setSourceEnabled(uint8,bool)", SRC, true));
        vm.stopPrank();

        vm.startPrank(publisher);
        for (uint256 i; i < vs.length; ++i) {
            _call(store, abi.encodeWithSignature("heartbeat(uint256,uint64)", vs[i], uint64(1)));
        }
        _write(store, V_SECOND, PRICE, 2);
        _write(store, V_MID, PRICE, 2);
        vm.warp(block.timestamp + 2 hours);
        _write(store, V_MID, PRICE, 3);
        uint64 cycle = 4;
        for (uint256 i; i < 50; ++i) {
            _write(store, V_WRAPPED, PRICE, cycle);
            cycle += 1;
            vm.warp(block.timestamp + 2 hours);
        }
        vm.stopPrank();
    }

    function test_gas_writePrice_first() public {
        _compare("writePrice:first", V_FIRST, PRICE, 2);
    }

    function test_gas_writePrice_second() public {
        vm.warp(block.timestamp + 2 hours);
        _compare("writePrice:second (ring slot cold)", V_SECOND, PRICE_MOVED, 3);
    }

    function test_gas_writePrice_midRing() public {
        vm.warp(block.timestamp + 2 hours);
        _compare("writePrice:writes 3-48 (ring slot fresh, counter warm)", V_MID, PRICE_MOVED, 4);
    }

    function test_gas_writePrice_wrapped() public {
        vm.warp(block.timestamp + 2 hours);
        _compare("writePrice:write 49+ (ring wrapped)", V_WRAPPED, PRICE_MOVED, 100);
    }

    // -------------------------------------------------------------------------

    function _compare(string memory name, uint256 validatorId, uint128 price, uint64 cycle) internal {
        bytes memory data = _writeCalldata(validatorId, price, cycle);
        uint256 cdGas = _calldataGas(data);
        uint256 onMain = _measure(address(mainStore), data);
        uint256 onDeployed = _measure(address(deployedStore), data);
        console2.log(
            string.concat(
                "ENG3913CMP,",
                name,
                ",main_exec=",
                vm.toString(onMain),
                ",deployed_exec=",
                vm.toString(onDeployed),
                ",delta_exec_deployed_minus_main=",
                onDeployed >= onMain
                    ? string.concat("+", vm.toString(onDeployed - onMain))
                    : string.concat("-", vm.toString(onMain - onDeployed)),
                ",calldataGas=",
                vm.toString(cdGas),
                ",main_tx=",
                vm.toString(21_000 + cdGas + onMain),
                ",deployed_tx=",
                vm.toString(21_000 + cdGas + onDeployed)
            )
        );
    }

    function _measure(address store, bytes memory data) internal returns (uint256) {
        vm.cool(store);
        // Warm the account, not its storage: `historyDepth` is immutable.
        _call(store, abi.encodeWithSignature("historyDepth()"));
        (bool warm,) = noop.call(data);
        require(warm, "control warm-up reverted");
        vm.prank(publisher);
        uint256 b0 = gasleft();
        (bool okNoop,) = noop.call(data);
        uint256 overhead = b0 - gasleft();
        require(okNoop, "control call reverted");
        vm.prank(publisher);
        uint256 b1 = gasleft();
        (bool ok,) = store.call(data);
        uint256 used = b1 - gasleft();
        require(ok, "measured call reverted");
        return used - overhead;
    }

    function _writeCalldata(uint256 validatorId, uint128 price, uint64 cycle) internal view returns (bytes memory) {
        FabricaAttributeOracle.PriceWriteParams memory p = FabricaAttributeOracle.PriceWriteParams({
            validatorId: validatorId,
            tokenId: TOKEN,
            sourceId: SRC,
            priceUsdc6: price,
            confidenceScore: 500,
            valuedAt: uint64(block.timestamp),
            cycle: cycle,
            provenance: _prov(publisher, uint256(cycle))
        });
        return abi.encodeCall(FabricaAttributeOracle.writePrice, (p));
    }

    function _write(address store, uint256 validatorId, uint128 price, uint64 cycle) internal {
        _call(store, _writeCalldata(validatorId, price, cycle));
    }

    function _call(address store, bytes memory data) internal {
        (bool ok, bytes memory ret) = store.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice Provenance for one write, with hashes that differ from every other write.
    /// @dev See the same helper in `Eng3913OracleGasBench`: constant provenance hashes
    ///      make two storage words no-op writes and understate every repeat write.
    function _prov(address signer, uint256 seed) internal view returns (FabricaAttributeOracle.Provenance memory) {
        return FabricaAttributeOracle.Provenance({
            rawPayloadHash: keccak256(abi.encodePacked("raw", seed)),
            inputsHash: keccak256(abi.encodePacked("inputs", seed)),
            timestamp: uint64(block.timestamp),
            signer: signer
        });
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 total) {
        for (uint256 i; i < data.length; ++i) {
            total += data[i] == 0 ? 4 : 16;
        }
    }

    function _knobs() internal pure returns (FabricaAttributeOracle.KnobConfig memory) {
        return FabricaAttributeOracle.KnobConfig({
            maxUpBps: 1500,
            maxDownBps: 5000,
            maxFirstPriceUsdc6: 50_000_000e6,
            maxSilence: 24 hours,
            minWriteInterval: 1 hours,
            registrySeasonDelay: 1 days,
            valueCeilingUsdc6: 50_000_000e6,
            historyDepth: 48
        });
    }

    function _deployedKnobs() internal pure returns (DeployedRound1FactStore.KnobConfig memory) {
        return DeployedRound1FactStore.KnobConfig({
            maxUpBps: 1500,
            maxDownBps: 5000,
            maxFirstPriceUsdc6: 50_000_000e6,
            maxSilence: 24 hours,
            minWriteInterval: 1 hours,
            registrySeasonDelay: 1 days,
            valueCeilingUsdc6: 50_000_000e6,
            historyDepth: 48
        });
    }
}
