// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FabricaFactStore} from "../src/FabricaFactStore.sol";

/// @notice Deploy the permissionless fact store. Introduced by ENG-3924 for round 2; used
///         unchanged by ENG-4203 to deploy the round-3 batched store.
/// @dev There is no owner argument and no knob argument, which is the point of the redeploy: the
///      round-1 deploy script (`FabricaAttributeOracleDeployScript`) had to take an owner, insist it
///      was a contract, and read back seven knobs. This one takes a history depth.
///
///      Sepolia only. Earlier stores — the round-1 store at
///      0xFfA7535eF090C9193f44399843a05b60808ffC0D and the round-2 store at
///      0xa81f30b0EC22DbE4b25239883850367EDB6f3Edd — are separate deployments and are not touched,
///      upgraded or superseded on chain by this script.
///
///      Usage:
///        forge script script/FabricaFactStoreDeploy.s.sol:FabricaFactStoreDeployScript \
///          --rpc-url sepolia --broadcast --verify
///      Reads FACT_STORE_HISTORY_DEPTH (default 48, matching the round-1 ring so a consumer's
///      seasoning walk has the same depth available) and the deployer key from the forge signer.
contract FabricaFactStoreDeployScript is Script {
    error HistoryDepthOutOfRange(uint256 depth);

    function run() external returns (FabricaFactStore store) {
        uint256 depth = vm.envOr("FACT_STORE_HISTORY_DEPTH", uint256(48));
        if (depth == 0 || depth > type(uint8).max) revert HistoryDepthOutOfRange(depth);
        vm.startBroadcast();
        // Bounded immediately above, so the narrowing cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        store = new FabricaFactStore(uint8(depth));
        vm.stopBroadcast();
        console.log("FabricaFactStore:", address(store));
        console.log("historyDepth:", store.historyDepth());
        console.log("KIND_PRICE:", vm.toString(store.KIND_PRICE()));
        console.log("Ownerless by construction: no owner, no allowlist, no knob, no gate.");
    }
}
