// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FabricaAttributeOracle} from "../src/FabricaAttributeOracle.sol";

abstract contract RuntimeDefaultsReader is Script {
    error DefaultsRuntimeUnavailable();

    function _etchRuntimeReader(string memory artifact, address reader) internal returns (address) {
        bytes memory runtime = vm.getDeployedCode(artifact);
        if (runtime.length == 0) revert DefaultsRuntimeUnavailable();
        vm.etch(reader, runtime);
        return reader;
    }
}

contract FabricaAttributeOracleDeployScript is RuntimeDefaultsReader {
    error InvalidAttributeOracleOwner();
    error AttributeOracleOwnerMustBeContract();
    error DefaultKnobsReadbackMismatch();

    address internal constant DEFAULTS_READER = 0x00000000000000000000000000000000Fa0D0001;

    function run() external returns (FabricaAttributeOracle oracle) {
        return _deploy(vm.envAddress("FABRICA_ATTRIBUTE_ORACLE_OWNER"));
    }

    function _deploy(address owner) internal returns (FabricaAttributeOracle oracle) {
        if (owner == address(0)) revert InvalidAttributeOracleOwner();
        if (owner.code.length == 0) revert AttributeOracleOwnerMustBeContract();
        FabricaAttributeOracle.KnobConfig memory knobs = _defaultKnobsFromContractRuntime();
        console2.log("FabricaAttributeOracle owner:", owner);
        _logKnobs("Default knobs:", knobs);
        console2.log("Owner must be a Safe/contract on every network.");
        vm.startBroadcast();
        oracle = new FabricaAttributeOracle(owner, knobs);
        vm.stopBroadcast();
        console2.log("FabricaAttributeOracle:", address(oracle));
        console2.log("Initialized owner:", oracle.owner());
        _assertLiveKnobs(oracle, knobs);
        _logKnobs("Live knob readback:", _liveKnobs(oracle));
    }

    function _defaultKnobsFromContractRuntime() internal returns (FabricaAttributeOracle.KnobConfig memory knobs) {
        address reader = _etchRuntimeReader("src/FabricaAttributeOracle.sol:FabricaAttributeOracle", DEFAULTS_READER);
        return FabricaAttributeOracle(reader).defaultKnobs();
    }

    function _logKnobs(string memory label, FabricaAttributeOracle.KnobConfig memory knobs) internal pure {
        console2.log(label);
        console2.log("  maxUpBps:", knobs.maxUpBps);
        console2.log("  maxDownBps:", knobs.maxDownBps);
        console2.log("  maxFirstPriceUsdc6:", knobs.maxFirstPriceUsdc6);
        console2.log("  maxSilence:", knobs.maxSilence);
        console2.log("  minWriteInterval:", knobs.minWriteInterval);
        console2.log("  registrySeasonDelay:", knobs.registrySeasonDelay);
        console2.log("  valueCeilingUsdc6:", knobs.valueCeilingUsdc6);
        console2.log("  historyDepth:", knobs.historyDepth);
    }

    function _assertLiveKnobs(FabricaAttributeOracle oracle, FabricaAttributeOracle.KnobConfig memory knobs)
        internal
        view
    {
        if (!_sameKnobs(knobs, _liveKnobs(oracle))) revert DefaultKnobsReadbackMismatch();
    }

    function _liveKnobs(FabricaAttributeOracle oracle)
        internal
        view
        returns (FabricaAttributeOracle.KnobConfig memory knobs)
    {
        knobs = FabricaAttributeOracle.KnobConfig({
            maxUpBps: oracle.maxUpBps(),
            maxDownBps: oracle.maxDownBps(),
            maxFirstPriceUsdc6: oracle.maxFirstPriceUsdc6(),
            maxSilence: oracle.maxSilence(),
            minWriteInterval: oracle.minWriteInterval(),
            registrySeasonDelay: oracle.registrySeasonDelay(),
            valueCeilingUsdc6: oracle.valueCeilingUsdc6(),
            historyDepth: oracle.historyDepth()
        });
    }

    function _sameKnobs(
        FabricaAttributeOracle.KnobConfig memory expected,
        FabricaAttributeOracle.KnobConfig memory actual
    ) internal pure returns (bool) {
        return expected.maxUpBps == actual.maxUpBps && expected.maxDownBps == actual.maxDownBps
            && expected.maxFirstPriceUsdc6 == actual.maxFirstPriceUsdc6 && expected.maxSilence == actual.maxSilence
            && expected.minWriteInterval == actual.minWriteInterval
            && expected.registrySeasonDelay == actual.registrySeasonDelay
            && expected.valueCeilingUsdc6 == actual.valueCeilingUsdc6 && expected.historyDepth == actual.historyDepth;
    }
}
