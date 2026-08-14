// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaMarketplaceZone} from "../src/FabricaMarketplaceZone.sol";
import {ZoneParameters, SpentItem, ReceivedItem, ItemType} from "../lib/seaport-types/src/lib/ConsiderationStructs.sol";

interface ISafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @notice ENG-3687: pins the LIVE Sepolia deployment of a FabricaMarketplaceZone whose
/// `oracleSigner` is a 2-of-2 Safe, and re-plays the exact ERC-1271 authorization that was
/// accepted on-chain by Seaport 1.6 in tx 0xbec9380c…dc9ddc.
/// @dev Every literal below is a real value captured from that run — the zone digest, the
/// Safe message hash, and the owner-signature blob are the same bytes the live fulfillment
/// carried. The fork block is the block the fulfillment landed in, so `block.timestamp`
/// sits inside the authorization's freshness window without any time manipulation.
contract FabricaMarketplaceZoneSepoliaErc1271ForkTest is Test {
    address internal constant ZONE = 0x892f9A7067a82Dbc49A3e557b08767C20fa1B061;
    address internal constant SAFE = 0xb9c4179D0b25b813a641B5809E7b0fd05483eAD8;
    address internal constant FABRICA_TOKEN = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    address internal constant SAFE_SINGLETON_1_4_1 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;

    uint256 internal constant SEPOLIA_FORK_BLOCK = 11_488_310;
    uint256 internal constant TOKEN_ID = 298855539945321607;
    uint64 internal constant EXPIRY = 1786727956;

    bytes32 internal constant ORDER_HASH = 0x31ac743402a7daec3e3e10311a33b766806faf162c328d925a57d3a094b8347b;
    bytes32 internal constant ZONE_DIGEST = 0x085069988deaacd6b7f1fe9f5b79ae5a4eb1dac28d210d4fcbafaa7f58fcd81c;
    bytes32 internal constant SAFE_MESSAGE_HASH = 0x2723e4acc561cd46a7e096d6d861cf04eca6c801a19201697c27908eb0a27352;

    string internal constant DEFINITION_URL = "ipfs://QmEng3687FregolottaZoneErc1271Proof";
    string internal constant DISCLOSURE_PACKAGE_ID = "e0036870-0000-4000-8000-000000003687";

    /// @dev Both Safe owners, signing SAFE_MESSAGE_HASH, concatenated in ascending owner order.
    bytes internal constant SIG_2_OF_2 =
        hex"7a9f16f0f44f0599071a7bcd93122447e25429ca8f7f71ac695c07815f1b50bf400bbdbde4a1d86593e646909dff25724d6b821fc1fa88417f3c6ac76b3c9c351b249db12b73b2c673c54674db6360d942a3803ebe1152e6e4f5081c95f50b65297d12ab7e17018b5abb83ef3e5a4bff29d0bbd0ca143648d199cc41fcc32f05f41b";
    /// @dev Only the lower-addressed owner — one signature short of the threshold.
    bytes internal constant SIG_1_OF_2 =
        hex"7a9f16f0f44f0599071a7bcd93122447e25429ca8f7f71ac695c07815f1b50bf400bbdbde4a1d86593e646909dff25724d6b821fc1fa88417f3c6ac76b3c9c351b";
    /// @dev A single EOA signing the RAW zone digest — the scheme fabrica-v3-api uses today.
    bytes internal constant SIG_EOA_OVER_RAW_DIGEST =
        hex"ec25ce6466503abb420c5937181a332dfc9ba619f40003a36ead9f4fbee776634eec92dd9e6302e12695d687b6bce3cbf75b3917b0aa1a13cfa99f67039acaa31c";

    function setUp() public {
        if (bytes(vm.envOr("SEPOLIA_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("sepolia", SEPOLIA_FORK_BLOCK);
        assertEq(block.chainid, 11155111, "SEPOLIA_RPC_URL must target Sepolia");
        assertGt(ZONE.code.length, 0, "zone not deployed at fork block");
        assertGt(SAFE.code.length, 0, "safe not deployed at fork block");
    }

    /// @dev The whole point of ENG-3687: the signer is a contract, so the zone takes its
    /// ERC-1271 branch instead of `ECDSA.recover`.
    function testFork_oracleSignerIsAContractSafe() public view {
        assertEq(FabricaMarketplaceZone(ZONE).oracleSigner(), SAFE, "oracleSigner must be the Safe");
        assertGt(SAFE.code.length, 0, "signer must have code to reach the ERC-1271 branch");
        assertEq(FabricaMarketplaceZone(ZONE).MAX_AGE(), 7 days, "MAX_AGE must stay 7 days");
    }

    function testFork_safeIsTwoOfTwo() public view {
        assertEq(ISafe(SAFE).getThreshold(), 2, "threshold");
        address[] memory owners = ISafe(SAFE).getOwners();
        assertEq(owners.length, 2, "owner count");
    }

    function testFork_safeValidatesTheTwoOfTwoSignature() public view {
        assertEq(
            ISafe(SAFE).isValidSignature(ZONE_DIGEST, SIG_2_OF_2),
            bytes4(0x1626ba7e),
            "Safe must return the ERC-1271 magic value"
        );
    }

    /// @dev Re-plays the authorization Seaport itself accepted on-chain.
    function testFork_authorizeAndValidateOrderAcceptSafeSignature() public view {
        ZoneParameters memory params = _zoneParameters(SIG_2_OF_2);
        assertEq(
            FabricaMarketplaceZone(ZONE).authorizeOrder(params),
            FabricaMarketplaceZone.authorizeOrder.selector,
            "authorizeOrder"
        );
        assertEq(
            FabricaMarketplaceZone(ZONE).validateOrder(params),
            FabricaMarketplaceZone.validateOrder.selector,
            "validateOrder"
        );
    }

    /// @dev Threshold is genuinely enforced through the zone, not just inside the Safe.
    function testFork_rejectsSignatureBelowThreshold() public {
        vm.expectRevert(bytes("GS020"));
        FabricaMarketplaceZone(ZONE).authorizeOrder(_zoneParameters(SIG_1_OF_2));
    }

    /// @dev This is the ENG-3687 hand-off to item 2: the signature shape fabrica-v3-api
    /// produces TODAY (one EOA signing the raw zone digest) does not authenticate against a
    /// Safe, so a config-only zone repoint cannot work for any Safe — 1-of-1 included.
    function testFork_rejectsEoaSignatureOverRawDigest() public {
        vm.expectRevert(bytes("GS020"));
        FabricaMarketplaceZone(ZONE).authorizeOrder(_zoneParameters(SIG_EOA_OVER_RAW_DIGEST));
    }

    function testFork_rejectsTamperedSignature() public {
        bytes memory tampered = SIG_2_OF_2;
        tampered[10] = bytes1(uint8(tampered[10]) ^ 0xFF);
        vm.expectRevert(bytes("GS026"));
        FabricaMarketplaceZone(ZONE).authorizeOrder(_zoneParameters(tampered));
    }

    /// @dev extraData layout: expiry(8) | defUrlLen(2) | defUrl(N) | dpId(36) | signature.
    function _zoneParameters(bytes memory signature) internal pure returns (ZoneParameters memory) {
        bytes memory definitionUrl = bytes(DEFINITION_URL);
        bytes memory extraData = abi.encodePacked(
            EXPIRY, uint16(definitionUrl.length), definitionUrl, bytes(DISCLOSURE_PACKAGE_ID), signature
        );
        SpentItem[] memory offer = new SpentItem[](1);
        offer[0] = SpentItem({itemType: ItemType.ERC1155, token: FABRICA_TOKEN, identifier: TOKEN_ID, amount: 1});
        bytes32[] memory orderHashes = new bytes32[](1);
        orderHashes[0] = ORDER_HASH;
        return ZoneParameters({
            orderHash: ORDER_HASH,
            fulfiller: address(0),
            offerer: address(0),
            offer: offer,
            consideration: new ReceivedItem[](0),
            extraData: extraData,
            orderHashes: orderHashes,
            startTime: 0,
            endTime: 0,
            zoneHash: bytes32(0)
        });
    }
}
