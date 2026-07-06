// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

abstract contract ForkTestBase is Test {
    // Skip when an optional fork RPC is absent, so ordinary `forge test` runs
    // stay green in environments without archive endpoints.
    function _forkOrSkip(string memory rpcEnvVar, string memory rpcAlias, uint256 blockNumber) internal returns (bool) {
        if (bytes(vm.envOr(rpcEnvVar, string(""))).length == 0) {
            emit log_named_string("SKIP (RPC env absent)", rpcEnvVar);
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpcAlias, blockNumber);
        return true;
    }

    // For manual FV, set requiredEnvVar to a nonempty value so a missing fork
    // RPC fails loudly instead of reporting a skipped proof.
    function _forkOrRequire(
        string memory rpcEnvVar,
        string memory rpcAlias,
        uint256 blockNumber,
        string memory requiredEnvVar
    ) internal returns (bool) {
        if (bytes(vm.envOr(rpcEnvVar, string(""))).length != 0) {
            vm.createSelectFork(rpcAlias, blockNumber);
            return true;
        }
        if (bytes(vm.envOr(requiredEnvVar, string(""))).length != 0) {
            revert(string.concat(rpcEnvVar, " is required when ", requiredEnvVar, " is set"));
        }
        emit log_named_string("SKIP (RPC env absent)", rpcEnvVar);
        vm.skip(true);
        return false;
    }
}
