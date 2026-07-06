// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

abstract contract ForkTestBase is Test {
    address internal constant SEPOLIA_FEE_PROXY_PROD = 0x404f53869aD67e167a8C89035f55572e653d7B22;
    address internal constant SEPOLIA_FEE_PROXY_STAGING = 0x98e819BF78081f4343E71Ed4096C59d74948C166;
    address internal constant SEPOLIA_FEE_PROXY_DEVELOP = 0x24888646723ae14C83E5354431753675A3d12D3c;
    string internal constant RPC_ENV_ABSENT_SKIP = "SKIP (RPC env absent)";

    struct ForkConfig {
        string rpcEnvVar;
        string rpcAlias;
        uint256 blockNumber;
        string requiredEnvVar;
    }

    // Skip when an optional fork RPC is absent, so ordinary `forge test` runs
    // stay green in environments without archive endpoints.
    function _forkOrSkip(ForkConfig memory config) internal returns (bool) {
        return _fork(config, false);
    }

    // For manual FV, set requiredEnvVar to a nonempty value so a missing fork
    // RPC fails loudly instead of reporting a skipped proof.
    function _forkOrRequire(ForkConfig memory config) internal returns (bool) {
        return _fork(config, true);
    }

    function _fork(ForkConfig memory config, bool honorRequiredFlag) private returns (bool) {
        if (bytes(vm.envOr(config.rpcEnvVar, string(""))).length != 0) {
            vm.createSelectFork(config.rpcAlias, config.blockNumber);
            return true;
        }
        if (honorRequiredFlag && bytes(vm.envOr(config.requiredEnvVar, string(""))).length != 0) {
            revert(string.concat(config.rpcEnvVar, " is required when ", config.requiredEnvVar, " is set"));
        }
        emit log_named_string(RPC_ENV_ABSENT_SKIP, config.rpcEnvVar);
        vm.skip(true);
        return false;
    }
}
