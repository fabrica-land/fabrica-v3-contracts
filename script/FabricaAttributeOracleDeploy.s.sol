// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {FabricaAttributeOracle} from "../src/FabricaAttributeOracle.sol";

contract FabricaAttributeOracleDeployScript is Script {
    error InvalidAttributeOracleOwner();
    error DefaultsRuntimeUnavailable();
    error DefaultKnobsReadbackMismatch();

    address internal constant DEFAULTS_READER = 0x00000000000000000000000000000000Fa0D0001;

    function run() external returns (FabricaAttributeOracle oracle) {
        return _deploy(vm.envAddress("FABRICA_ATTRIBUTE_ORACLE_OWNER"));
    }

    function _deploy(address owner) internal returns (FabricaAttributeOracle oracle) {
        if (owner == address(0)) revert InvalidAttributeOracleOwner();

        FabricaAttributeOracle.KnobConfig memory knobs = _defaultKnobsFromContractRuntime();

        console2.log("FabricaAttributeOracle owner:", owner);
        _logKnobs("Default knobs:", knobs);
        console2.log("Sepolia owner may be an EOA; mainnet owner must be a Safe.");

        vm.startBroadcast();
        oracle = new FabricaAttributeOracle(owner, knobs);
        vm.stopBroadcast();

        console2.log("FabricaAttributeOracle:", address(oracle));
        console2.log("Initialized owner:", oracle.owner());

        FabricaAttributeOracle.KnobConfig memory deployedDefaults = oracle.defaultKnobs();
        if (!_sameKnobs(knobs, deployedDefaults)) revert DefaultKnobsReadbackMismatch();
        _assertLiveKnobs(oracle, knobs);
        _logLiveKnobs(oracle);
    }

    function _defaultKnobsFromContractRuntime() internal returns (FabricaAttributeOracle.KnobConfig memory knobs) {
        bytes memory runtime = vm.getDeployedCode("src/FabricaAttributeOracle.sol:FabricaAttributeOracle");
        if (runtime.length == 0) revert DefaultsRuntimeUnavailable();

        vm.etch(DEFAULTS_READER, runtime);
        return FabricaAttributeOracle(DEFAULTS_READER).defaultKnobs();
    }

    function _sameKnobs(FabricaAttributeOracle.KnobConfig memory a, FabricaAttributeOracle.KnobConfig memory b)
        internal
        pure
        returns (bool)
    {
        return a.maxUpBps == b.maxUpBps && a.maxDownBps == b.maxDownBps && a.maxFirstPriceUsdc6 == b.maxFirstPriceUsdc6
            && a.maxSilence == b.maxSilence && a.minWriteInterval == b.minWriteInterval
            && a.registrySeasonDelay == b.registrySeasonDelay && a.valueCeilingUsdc6 == b.valueCeilingUsdc6
            && a.historyDepth == b.historyDepth;
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
        if (
            oracle.maxUpBps() != knobs.maxUpBps || oracle.maxDownBps() != knobs.maxDownBps
                || oracle.maxFirstPriceUsdc6() != knobs.maxFirstPriceUsdc6 || oracle.maxSilence() != knobs.maxSilence
                || oracle.minWriteInterval() != knobs.minWriteInterval
                || oracle.registrySeasonDelay() != knobs.registrySeasonDelay
                || oracle.valueCeilingUsdc6() != knobs.valueCeilingUsdc6 || oracle.historyDepth() != knobs.historyDepth
        ) {
            revert DefaultKnobsReadbackMismatch();
        }
    }

    function _logLiveKnobs(FabricaAttributeOracle oracle) internal view {
        console2.log("Live knob readback:");
        console2.log("  maxUpBps:", oracle.maxUpBps());
        console2.log("  maxDownBps:", oracle.maxDownBps());
        console2.log("  maxFirstPriceUsdc6:", oracle.maxFirstPriceUsdc6());
        console2.log("  maxSilence:", oracle.maxSilence());
        console2.log("  minWriteInterval:", oracle.minWriteInterval());
        console2.log("  registrySeasonDelay:", oracle.registrySeasonDelay());
        console2.log("  valueCeilingUsdc6:", oracle.valueCeilingUsdc6());
        console2.log("  historyDepth:", oracle.historyDepth());
    }
}
