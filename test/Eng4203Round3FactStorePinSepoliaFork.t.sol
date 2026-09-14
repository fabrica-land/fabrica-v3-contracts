// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ForkTestBase} from "./ForkTestBase.sol";
import {FabricaImmutableAggregatorDeployScript} from "../script/FabricaImmutableAggregatorDeploy.s.sol";

/**
 * ENG-4203 — the aggregator deploy script's pinned fact store, asserted against the real chain.
 *
 * The unit suite cannot establish this. Its fixtures `vm.etch` a freshly compiled round-3 store AT
 * whatever address the pin names, so every assertion about the pinned address is true by
 * construction and any valid-checksum address would pass. That leaves the repo unable to tell a
 * correct pin from an incorrect one — the binding it produces is an `immutable`, so a wrong pin is
 * permanent and unfixable.
 *
 * This suite reads the pinned address on a pinned Sepolia block and asserts the four properties
 * that distinguish a round-3 store from every superseded generation. Nothing here is constructed.
 *
 *   forge test --match-contract Eng4203Round3FactStorePinSepoliaForkTest -vv
 *
 * Without SEPOLIA_RPC_URL this suite SKIPS. A skip proves nothing, so CI runs it in its own step
 * that supplies the secret; set FABRICA_REQUIRE_SEPOLIA_FV=1 to make a missing RPC a loud failure.
 */
contract Eng4203Round3FactStorePinSepoliaForkTest is ForkTestBase {
    /// @dev Pinned after the ENG-4203 round-3 store was deployed at block 11,704,139.
    uint256 internal constant FORK_BLOCK = 11_704_568;

    /// @notice Round-3 runtime size, as deployed and Etherscan-verified.
    uint256 internal constant ROUND3_RUNTIME_BYTES = 6393;

    /// @notice Superseded generations, retained so the discriminator is shown to discriminate.
    address internal constant ROUND2_FACT_STORE = 0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd;
    address internal constant DEAD_ROUND2_FACT_STORE = 0x89895c2fCC975c16AeAd2e213d2076dbF0aeb8b8;

    function setUp() public {
        _forkOrRequire(
            ForkConfig({
                rpcEnvVar: "SEPOLIA_RPC_URL",
                rpcAlias: "sepolia",
                blockNumber: FORK_BLOCK,
                requiredEnvVar: "FABRICA_REQUIRE_SEPOLIA_FV"
            })
        );
    }

    /// @notice The address the script pins is a real, deployed, round-3-generation fact store.
    function test_fork_pinnedFactStoreIsARound3Store() public {
        address pinned = _pinnedFactStore();
        assertEq(pinned.code.length, ROUND3_RUNTIME_BYTES, "pinned store runtime size");
        assertEq(_staticUint(pinned, "historyDepth()"), 48, "pinned store historyDepth");
        assertEq(_staticUint(pinned, "MAX_BATCH()"), 256, "pinned store MAX_BATCH");
        assertEq(
            bytes32(_staticUint(pinned, "KIND_PRICE()")), keccak256("fabrica.fact.price"), "pinned store KIND_PRICE"
        );
    }

    /// @notice The property the guard tests genuinely separates round 3 from both superseded stores.
    /// @dev Without this the `MAX_BATCH()` check could be vacuous — a discriminator that every
    ///      candidate satisfies discriminates nothing. Both superseded stores are live on chain at
    ///      this block and neither answers the call.
    function test_fork_supersededStoresCannotAnswerMaxBatch() public view {
        assertGt(ROUND2_FACT_STORE.code.length, 0, "round-2 store still deployed");
        assertGt(DEAD_ROUND2_FACT_STORE.code.length, 0, "dead round-2 store still deployed");
        (bool roundTwoOk,) = ROUND2_FACT_STORE.staticcall(abi.encodeWithSignature("MAX_BATCH()"));
        assertFalse(roundTwoOk, "round-2 store must not answer MAX_BATCH");
        (bool deadOk,) = DEAD_ROUND2_FACT_STORE.staticcall(abi.encodeWithSignature("MAX_BATCH()"));
        assertFalse(deadOk, "dead round-2 store must not answer MAX_BATCH");
    }

    /// @dev Reads the pin out of the script itself rather than restating the literal, so this suite
    ///      cannot drift away from the constant it exists to verify.
    function _pinnedFactStore() private returns (address) {
        FabricaImmutableAggregatorDeployScript script = new FabricaImmutableAggregatorDeployScript();
        return script.pinnedFactStore();
    }

    function _staticUint(address target, string memory signature) private view returns (uint256) {
        (bool ok, bytes memory returned) = target.staticcall(abi.encodeWithSignature(signature));
        require(ok && returned.length == 32, signature);
        return abi.decode(returned, (uint256));
    }
}
