// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

abstract contract ForkTestBase is Test {
    struct ForkConfig {
        string rpcEnvVar;
        string rpcAlias;
        uint256 blockNumber;
        string requiredEnvVar;
    }

    // Skip when an optional fork RPC is absent, so ordinary `forge test` runs
    // stay green in environments without archive endpoints.
    function _forkOrSkip(ForkConfig memory config) internal returns (bool) {
        if (bytes(vm.envOr(config.rpcEnvVar, string(""))).length == 0) {
            emit log_named_string("SKIP (RPC env absent)", config.rpcEnvVar);
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(config.rpcAlias, config.blockNumber);
        return true;
    }

    // For manual FV, set requiredEnvVar to a nonempty value so a missing fork
    // RPC fails loudly instead of reporting a skipped proof.
    function _forkOrRequire(ForkConfig memory config) internal returns (bool) {
        if (bytes(vm.envOr(config.rpcEnvVar, string(""))).length != 0) {
            vm.createSelectFork(config.rpcAlias, config.blockNumber);
            return true;
        }
        if (bytes(vm.envOr(config.requiredEnvVar, string(""))).length != 0) {
            revert(string.concat(config.rpcEnvVar, " is required when ", config.requiredEnvVar, " is set"));
        }
        emit log_named_string("SKIP (RPC env absent)", config.rpcEnvVar);
        vm.skip(true);
        return false;
    }
}
