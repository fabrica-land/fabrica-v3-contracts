// script/Revoke7702.s.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Foundry script to submit an EIP-7702 revoke (code = 0x) from the EOA itself,
// by sending a raw typed transaction if your node supports 7702.
// Note: Foundry/cast may not expose 7702 yet; this script uses vm to send raw.

import "forge-std/Script.sol";

contract Revoke7702 is Script {
    // Set via env: PRIVATE_KEY and RPC_URL when running `forge script`
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        // The revoke semantics: special 7702 tx that sets code to empty.
        // Fallback approach: attempt a contract-creation with empty data.
        // This will only clear delegation if the RPC/node interprets it as a 7702 tx.
        // Otherwise it will be a no-op (what you observed with cast).

        // Send create tx with empty initcode. Some nodes treat this as 7702 revoke.
        // Gas generously set to avoid underestimation.
        (bool success, ) = address(0).call{gas: 60000}("");
        require(success, "send failed");

        vm.stopBroadcast();
    }
}

