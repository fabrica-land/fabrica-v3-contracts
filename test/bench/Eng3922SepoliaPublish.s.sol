// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IEAS, AttestationRequest, AttestationRequestData, MultiAttestationRequest} from "./eas/IEAS.sol";
import {OwnerlessFactStore} from "./OwnerlessFactStore.sol";

/// @notice ENG-3922 — phase 1 of the real Sepolia cycle: everything that does not need a uid.
/// @dev Per writer: one `multiAttest` of the cycle's prices, one batched write into the ownerless
///      store, one cycle-close attestation, one cycle-close heartbeat. The pointer writes and the
///      indexing follow in phase 2, because both need the uids this phase creates and an EAS uid
///      is not knowable before the transaction lands.
contract Eng3922SepoliaPublishScript is Script {
    address internal constant EAS = 0xC2679fBD37d54388Ce493F1DB75320D236e1815e;
    uint256 internal constant CYCLE_TOKENS = 20;

    IEAS internal eas = IEAS(EAS);

    function run() external {
        bytes32 priceSchema = vm.envBytes32("PRICE_SCHEMA");
        bytes32 cycleCloseSchema = vm.envBytes32("CYCLE_CLOSE_SCHEMA");
        OwnerlessFactStore store = OwnerlessFactStore(vm.envAddress("OWNERLESS_STORE"));
        uint64 cycle = uint64(vm.envUint("CYCLE"));
        uint256[3] memory keys = [vm.envUint("W0_KEY"), vm.envUint("W1_KEY"), vm.envUint("W2_KEY")];

        for (uint256 w; w < 3; ++w) {
            _publishFor(keys[w], uint8(w), cycle, priceSchema, cycleCloseSchema, store);
        }
    }

    struct Payload {
        uint256[] ids;
        uint128[] prices;
        uint24[] confs;
        uint64[] valuedAts;
        AttestationRequestData[] data;
    }

    function _payload(uint8 sourceId, uint64 cycle) internal view returns (Payload memory pl) {
        pl.ids = new uint256[](CYCLE_TOKENS);
        pl.prices = new uint128[](CYCLE_TOKENS);
        pl.confs = new uint24[](CYCLE_TOKENS);
        pl.valuedAts = new uint64[](CYCLE_TOKENS);
        pl.data = new AttestationRequestData[](CYCLE_TOKENS);
        for (uint256 i; i < CYCLE_TOKENS; ++i) {
            uint256 tokenId = _tokenIdAt(i);
            uint128 p = uint128(100_000e6 + i * 1_000e6 + uint256(cycle) * 500e6);
            pl.ids[i] = tokenId;
            pl.prices[i] = p;
            pl.confs[i] = 9000;
            pl.valuedAts[i] = uint64(block.timestamp);
            pl.data[i] = AttestationRequestData({
                recipient: address(uint160(tokenId)),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: _priceData(tokenId, sourceId, p, cycle),
                value: 0
            });
        }
    }

    function _priceData(uint256 tokenId, uint8 sourceId, uint128 p, uint64 cycle) internal pure returns (bytes memory) {
        return abi.encode(
            tokenId, sourceId, p, uint24(9000), cycle, keccak256(abi.encode("inputs", tokenId, sourceId, cycle))
        );
    }

    function _publishFor(
        uint256 key,
        uint8 sourceId,
        uint64 cycle,
        bytes32 priceSchema,
        bytes32 cycleCloseSchema,
        OwnerlessFactStore store
    ) internal {
        address writer = vm.addr(key);
        Payload memory pl = _payload(sourceId, cycle);
        MultiAttestationRequest[] memory req = new MultiAttestationRequest[](1);
        req[0] = MultiAttestationRequest({schema: priceSchema, data: pl.data});
        vm.startBroadcast(key);
        eas.multiAttest(req);
        // Root is deliberately zero: Tim ruled at 18:47Z that round 2's cycle close carries the
        // cycle number ONLY. The Merkle root is a round-3 candidate (proposal item 13) and its
        // cost is measured separately in Eng3922Write.t.sol rather than paid for here.
        store.writePriceBatch(pl.ids, pl.prices, pl.confs, pl.valuedAts, cycle, bytes32(0));
        eas.attest(
            AttestationRequest({
                schema: cycleCloseSchema,
                data: AttestationRequestData({
                    recipient: writer,
                    expirationTime: 0,
                    revocable: true,
                    refUID: bytes32(0),
                    data: abi.encode(writer, cycle, bytes32(0)),
                    value: 0
                })
            })
        );
        // NOT redundant with writePriceBatch's heartbeat touch. The glossary makes the explicit
        // heartbeat the "book confirmed" signal and states that a plain write does not count as a
        // heartbeat for the fail-closed gate, so a real writer sends it even on a cycle where it
        // published prices. It is also the operation measured as the standalone cycle-close cost.
        store.heartbeat(cycle, bytes32(0));
        vm.stopBroadcast();
    }

    function _tokenIdAt(uint256 i) internal pure returns (uint256) {
        return uint256(uint64(uint256(keccak256(abi.encode("eng3922-sepolia-token", i)))));
    }
}
