// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FabricaMarketplaceZone} from "../src/FabricaMarketplaceZone.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {ZoneAuthorizationFixture} from "./ZoneAuthorizationFixture.sol";
import {SafeLikeErc1271Signer} from "./SafeLikeErc1271Signer.sol";
import {ZoneParameters} from "../lib/seaport-types/src/lib/ConsiderationStructs.sol";

interface ISafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function getMessageHash(bytes memory message) external view returns (bytes32);
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

interface IERC1155Balance {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface ISeaportOrderStatus {
    function getOrderStatus(bytes32 orderHash)
        external
        view
        returns (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize);
}

/// @notice ENG-3687 DEPLOYMENT ATTESTATION for the Sepolia MarketplaceZone whose `oracleSigner`
/// is a Safe rather than an EOA.
/// @dev This is deliberately NOT regression coverage for `src/FabricaMarketplaceZone.sol`. Its
/// zone assertions target already-deployed, immutable bytecode at a pinned historical block, so
/// no edit to `src/FabricaMarketplaceZone.sol` can make them fail. (One test here is not of that
/// kind by design: `testFork_safeLikeModelMatchesTheLiveSafeReWrapFormula` deliberately compares
/// the LOCAL SafeLikeErc1271Signer against the live Safe, and will fail if that model drifts.) Its job is to attest that the ENG-3687
/// deployment behaves as documented, and to pin the ERC-1271 facts the item-2 custody decision
/// rests on. Source-level regression coverage for the same behaviour — including a Safe-shaped
/// signer that runs with no RPC — lives in `FabricaMarketplaceZone.t.sol`.
/// @dev The digest-relevant inputs (orderHash, expiry, definitionUrl, disclosurePackageId) are
/// the exact values the live fulfillment carried in tx 0xbec9380c…dc9ddc. The remaining
/// `ZoneParameters` fields are re-derived rather than replayed: `_verify` never reads them, and
/// they are set to zero here. Consequence worth naming: with an empty `consideration`, the
/// consideration-side branch of `_verifyDefinitionUrl` is not exercised by this file.
contract FabricaMarketplaceZoneSepoliaErc1271ForkTest is ForkTestBase {
    address internal constant ZONE = 0x892f9A7067a82Dbc49A3e557b08767C20fa1B061;
    address internal constant FABRICA_TOKEN = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    address internal constant SEAPORT_1_6 = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant SAFE_SINGLETON_1_4_1 = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SELLER = 0xBF03076547a99857b796717faF4034dea94569dF;
    address internal constant BUYER = 0x59d0b67A4F67149E4A3a7615B9d5e5D153BDa9c8;

    /// @dev The 2-of-2 Safe that signed the live fulfillment.
    address internal constant SAFE_2_OF_2 = 0xb9c4179D0b25b813a641B5809E7b0fd05483eAD8;
    address internal constant SAFE_2_OF_2_OWNER_A = 0x0af6aaDc74927B7A5cbd8Ab339834c38b10f3b3F;
    address internal constant SAFE_2_OF_2_OWNER_B = 0xbC6718D825B41ED0Bdee0D8e269B3644e728EDeD;

    /// @dev A second, 1-of-1 Safe. It exists solely so the "an EOA signature over the raw zone
    /// digest cannot authenticate against a Safe" claim can be tested where the threshold length
    /// gate does NOT fire — see testFork_1of1 tests below.
    /// @dev Its sole owner is SAFE_2_OF_2_OWNER_A — the SAME key, deliberately. That is what makes
    /// the control pair decisive: the only variable between the two 65-byte blobs is which hash
    /// was signed, not who signed it.
    address internal constant SAFE_1_OF_1 = 0xF19896681Fe823a07044E8D58B2E25374771f3f2;

    /// @dev USABLE WINDOW is [11_488_385, ~11_488_607] and BOTH ends bite.
    /// Upper: this block's timestamp is 1786725348 and EXPIRY is 1786727956, leaving 2608 seconds
    /// (~217 Sepolia blocks). Past the ceiling the positive tests revert "Oracle signature
    /// expired" and the zone-level NEGATIVE tests fail too, because they assert GS020/GS026 and
    /// would instead see the expiry revert. The owner keys are destroyed at wrap-up, so nothing
    /// can ever be re-signed.
    /// Lower: the 1-of-1 control Safe was deployed at block 11_488_385, so pinning below that
    /// makes every testFork_1of1* call a non-contract.
    /// Do not routinely bump this; retire the file with item 2 instead. setUp asserts the upper
    /// bound so a bump fails loudly rather than mysteriously.
    uint256 internal constant SEPOLIA_FORK_BLOCK = 11_488_390;
    uint256 internal constant TOKEN_ID = 298855539945321607;
    uint64 internal constant EXPIRY = 1786727956;
    uint256 internal constant SELLER_ETH_BALANCE_AT_FORK = 4_664_981_375_599_892_010;
    uint256 internal constant BUYER_ETH_BALANCE_AT_FORK = 48_275_666_627_620_782;

    bytes32 internal constant ORDER_HASH = 0x31ac743402a7daec3e3e10311a33b766806faf162c328d925a57d3a094b8347b;
    bytes32 internal constant ZONE_DIGEST = 0x085069988deaacd6b7f1fe9f5b79ae5a4eb1dac28d210d4fcbafaa7f58fcd81c;
    /// @dev What the 2-of-2 Safe re-wraps ZONE_DIGEST into before checking signatures.
    bytes32 internal constant SAFE_MESSAGE_HASH_2_OF_2 =
        0x2723e4acc561cd46a7e096d6d861cf04eca6c801a19201697c27908eb0a27352;
    /// @dev The same re-wrap performed by the 1-of-1 Safe — a different value, because the Safe's
    /// own address is part of its EIP-712 domain.
    bytes32 internal constant SAFE_MESSAGE_HASH_1_OF_1 =
        0x4b054134624fbc5d59e113557dec2fb88c7ecc204ad7219b55f9df42980deb61;
    /// @dev A digest for an unrelated message, used to prove SIG_2OF2_FOR_OTHER_ORDER is a
    /// genuine Safe authorization somewhere before asserting it is not one here. Provenance:
    /// keccak256("eng3687-some-other-order-digest"), asserted below so it is derived rather than
    /// magic, and asserted distinct from ZONE_DIGEST.
    bytes32 internal constant OTHER_ZONE_DIGEST = 0x97849da5b911f7ab54c306eba9248ce0a17d94f9ae6ddebfa16a6988638f5c79;
    bytes32 internal constant SAFE_FALLBACK_HANDLER_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;
    address internal constant SAFE_COMPATIBILITY_FALLBACK_HANDLER_1_4_1 = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    string internal constant DEFINITION_URL = "ipfs://QmEng3687FregolottaZoneErc1271Proof";
    string internal constant DISCLOSURE_PACKAGE_ID = "e0036870-0000-4000-8000-000000003687";

    /// @dev Both owners over SAFE_MESSAGE_HASH_2_OF_2, ascending owner order. The live blob.
    bytes internal constant SIG_2OF2_VALID =
        hex"7a9f16f0f44f0599071a7bcd93122447e25429ca8f7f71ac695c07815f1b50bf400bbdbde4a1d86593e646909dff25724d6b821fc1fa88417f3c6ac76b3c9c351b249db12b73b2c673c54674db6360d942a3803ebe1152e6e4f5081c95f50b65297d12ab7e17018b5abb83ef3e5a4bff29d0bbd0ca143648d199cc41fcc32f05f41b";
    /// @dev Both owners, correct LENGTH, but signing the raw zone digest instead of the Safe
    /// message hash. Passes the threshold length gate and fails on owner recovery — this is the
    /// control that isolates domain-wrapping from length.
    bytes internal constant SIG_2OF2_OVER_RAW_DIGEST =
        hex"ec25ce6466503abb420c5937181a332dfc9ba619f40003a36ead9f4fbee776634eec92dd9e6302e12695d687b6bce3cbf75b3917b0aa1a13cfa99f67039acaa31c934964ca6c1c2d0fef5dfa6556bef17a9c1519b79307f5c358174447441a56a839c4f07dad65f680ca0b0b0d49a1dc4a3d28ec8527233a01ab8ed3a7d1e8db6d1c";
    /// @dev Two well-formed signatures over the correct hash from keys that are not owners.
    bytes internal constant SIG_2OF2_NON_OWNERS =
        hex"b1a6c581390e5b3ed9e03f6e263ba450a663b9fd1802a604a76655eee60bfc5629aa1886e0c00e17325493ed2788d8008804f110fd70539e4f177db024584d061bb6443d0bd939b69d1054944047ad67158fa3b821a3bdc1a54be68a116eeb4a7920a67b97632c832e66dee5f1753f54197b861415e3ce9b441ec046a9b3b8dfd31b";
    /// @dev A genuinely valid 2-of-2 authorization, but for a DIFFERENT order. Proves the
    /// authorization is bound to its orderHash.
    bytes internal constant SIG_2OF2_FOR_OTHER_ORDER =
        hex"f7da3deb08f866ee21c028e59362621c7c97a630cdef009c8dca53a675795f5218583e0488ffc41405fe71d938b814c8ce5ad10ab630c58171309fda1d5daab91b9455e5e44fe0fd38945b6349e406d386c4a7660d20dad450eec430900bb30131460ff7c48437cc651402e62b7200a05690bba1b969709252cbc491f0b0057ee21b";
    /// @dev Single owner over SAFE_MESSAGE_HASH_1_OF_1 — the shape a Safe-aware signer produces.
    bytes internal constant SIG_1OF1_VALID =
        hex"a372b1ad80b4143bd522ebccd013ff2cbb746cc476a14d952caf0ddd1288009d1285f81d2eb43819eb99f7aa9dd2813c34d0c8c5b0531c12e4ec7dc70cb58c7e1c";
    /// @dev Single owner over the RAW zone digest — byte-for-byte the shape fabrica-v3-api emits
    /// today. Same length as SIG_1OF1_VALID, so the length gate cannot explain the difference.
    bytes internal constant SIG_1OF1_OVER_RAW_DIGEST =
        hex"ec25ce6466503abb420c5937181a332dfc9ba619f40003a36ead9f4fbee776634eec92dd9e6302e12695d687b6bce3cbf75b3917b0aa1a13cfa99f67039acaa31c";

    function setUp() public {
        // requiredEnvVar lets a manual FV run fail loudly instead of silently reporting a skip.
        _forkOrRequire(
            ForkConfig({
                rpcEnvVar: "SEPOLIA_RPC_URL",
                rpcAlias: "sepolia",
                blockNumber: SEPOLIA_FORK_BLOCK,
                requiredEnvVar: "ENG3687_REQUIRE_FORK"
            })
        );
        if (block.number == 0) {
            return;
        }
        assertLt(block.timestamp, EXPIRY, "fork block is past the authorization expiry - see USABLE WINDOW");
        assertGe(block.number, 11_488_385, "fork block is below the 1-of-1 control Safe's deploy block");
    }

    /// @dev The whole point of ENG-3687: the signer is a contract, so the zone takes its
    /// ERC-1271 branch instead of `ECDSA.recover`.
    function testFork_oracleSignerIsAContractSafe() public view {
        assertEq(FabricaMarketplaceZone(ZONE).oracleSigner(), SAFE_2_OF_2, "oracleSigner must be the Safe");
        assertGt(SAFE_2_OF_2.code.length, 0, "signer must have code to reach the ERC-1271 branch");
    }

    /// @dev Freshness window is unchanged from the EOA-signer deployments.
    function testFork_maxAgeIsUnchanged() public view {
        assertEq(FabricaMarketplaceZone(ZONE).MAX_AGE(), 7 days, "MAX_AGE must stay 7 days");
    }

    /// @dev Pins the Safe's configuration, not merely its owner count — a different 2-owner Safe
    /// would otherwise satisfy this.
    function testFork_safeIsTwoOfTwoWithTheDocumentedOwners() public view {
        assertEq(ISafe(SAFE_2_OF_2).getThreshold(), 2, "threshold");
        address[] memory owners = ISafe(SAFE_2_OF_2).getOwners();
        assertEq(owners.length, 2, "owner count");
        assertEq(owners[0], SAFE_2_OF_2_OWNER_A, "owner A");
        assertEq(owners[1], SAFE_2_OF_2_OWNER_B, "owner B");
        assertEq(address(uint160(uint256(vm.load(SAFE_2_OF_2, bytes32(0))))), SAFE_SINGLETON_1_4_1, "singleton");
        assertEq(
            address(uint160(uint256(vm.load(SAFE_2_OF_2, SAFE_FALLBACK_HANDLER_SLOT)))),
            SAFE_COMPATIBILITY_FALLBACK_HANDLER_1_4_1,
            "fallback handler is load-bearing: a zero handler answers no ERC-1271 at all"
        );
    }

    /// @dev The 1-of-1 control pair is only decisive if its premises hold: threshold really is 1
    /// (so the length gate cannot fire) and its owner really is the key that signed both blobs.
    function testFork_1of1SafeConfigurationMakesTheControlPairDecisive() public view {
        assertEq(ISafe(SAFE_1_OF_1).getThreshold(), 1, "threshold must be 1 or the length gate fires");
        address[] memory owners = ISafe(SAFE_1_OF_1).getOwners();
        assertEq(owners.length, 1, "owner count");
        assertEq(owners[0], SAFE_2_OF_2_OWNER_A, "owner");
        assertEq(address(uint160(uint256(vm.load(SAFE_1_OF_1, bytes32(0))))), SAFE_SINGLETON_1_4_1, "singleton");
        assertEq(
            address(uint160(uint256(vm.load(SAFE_1_OF_1, SAFE_FALLBACK_HANDLER_SLOT)))),
            SAFE_COMPATIBILITY_FALLBACK_HANDLER_1_4_1,
            "fallback handler"
        );
        // both control blobs must come from that same owner, or GS026 is attributable to
        // non-ownership rather than to the hash that was signed
        assertEq(_recoverSingle(SIG_1OF1_VALID, SAFE_MESSAGE_HASH_1_OF_1), owners[0], "valid blob signer");
        assertEq(_recoverSingle(SIG_1OF1_OVER_RAW_DIGEST, ZONE_DIGEST), owners[0], "raw-digest blob signer");
    }

    /// @dev Binds each pinned constant to the claim its name makes, so a typo degrades a control
    /// into a failure rather than silently back into a vacuous pass.
    function testFork_pinnedSignatureConstantsAreWhatTheyClaim() public view {
        assertEq(_recoverAt(SIG_2OF2_VALID, 0, SAFE_MESSAGE_HASH_2_OF_2), SAFE_2_OF_2_OWNER_A, "valid[0]");
        assertEq(_recoverAt(SIG_2OF2_VALID, 1, SAFE_MESSAGE_HASH_2_OF_2), SAFE_2_OF_2_OWNER_B, "valid[1]");
        assertEq(_recoverAt(SIG_2OF2_OVER_RAW_DIGEST, 0, ZONE_DIGEST), SAFE_2_OF_2_OWNER_A, "raw-digest[0]");
        assertEq(_recoverAt(SIG_2OF2_OVER_RAW_DIGEST, 1, ZONE_DIGEST), SAFE_2_OF_2_OWNER_B, "raw-digest[1]");
        // the non-owner control: without this its GS026 is equally consistent with garbage bytes
        // recovering to address(0), which is the vacuity this board caught three times
        address nonOwnerA = _recoverAt(SIG_2OF2_NON_OWNERS, 0, SAFE_MESSAGE_HASH_2_OF_2);
        address nonOwnerB = _recoverAt(SIG_2OF2_NON_OWNERS, 1, SAFE_MESSAGE_HASH_2_OF_2);
        assertTrue(nonOwnerA != address(0) && nonOwnerB != address(0), "non-owner sigs must be well formed");
        assertTrue(nonOwnerA < nonOwnerB, "non-owner sigs must be in ascending order");
        assertTrue(nonOwnerA != SAFE_2_OF_2_OWNER_A && nonOwnerA != SAFE_2_OF_2_OWNER_B, "slot 0 must not be an owner");
        assertTrue(nonOwnerB != SAFE_2_OF_2_OWNER_A && nonOwnerB != SAFE_2_OF_2_OWNER_B, "slot 1 must not be an owner");
    }

    /// @dev The attestation must be sensitive to the bytes it actually sends. Without this,
    /// changing the shared extraData builder leaves this file passing while the CI suite fails.
    function testFork_extraDataIsTheDocumentedTwoHundredEighteenBytes() public view {
        ZoneParameters memory params = _zoneParameters(SIG_2OF2_VALID);
        assertEq(params.extraData.length, 218, "expiry(8)|defUrlLen(2)|defUrl(42)|dpId(36)|sig(130)");
    }

    function testFork_otherZoneDigestProvenance() public pure {
        assertEq(OTHER_ZONE_DIGEST, keccak256("eng3687-some-other-order-digest"), "derived, not magic");
        assertTrue(OTHER_ZONE_DIGEST != ZONE_DIGEST, "must differ from the order under test");
    }

    /// @dev SIG_2OF2_FOR_OTHER_ORDER is only an order-binding control if it is a REAL
    /// authorization for some other order. Prove that first, then prove it does not authorize
    /// this one — otherwise it is indistinguishable from arbitrary non-owner bytes.
    function testFork_orderBindingControlIsAGenuineAuthorizationElsewhere() public view {
        assertEq(
            ISafe(SAFE_2_OF_2).isValidSignature(OTHER_ZONE_DIGEST, SIG_2OF2_FOR_OTHER_ORDER),
            bytes4(0x1626ba7e),
            "must be a valid 2-of-2 authorization for the other order"
        );
    }

    /// @dev Pins SafeLikeErc1271Signer (the no-RPC model in FabricaMarketplaceZone.t.sol) to the
    /// LIVE Safe's re-wrap formula. Without this the model validates only against itself and can
    /// drift from upstream Safe silently.
    function testFork_safeLikeModelMatchesTheLiveSafeReWrapFormula() public {
        bytes32 domainTypehash = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
        bytes32 safeMsgTypehash = keccak256("SafeMessage(bytes message)");
        bytes32 expectedForLiveSafe = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                keccak256(abi.encode(domainTypehash, block.chainid, SAFE_2_OF_2)),
                keccak256(abi.encode(safeMsgTypehash, keccak256(abi.encode(ZONE_DIGEST))))
            )
        );
        assertEq(ISafe(SAFE_2_OF_2).getMessageHash(abi.encode(ZONE_DIGEST)), expectedForLiveSafe, "live Safe formula");
        address[] memory owners = new address[](1);
        owners[0] = SAFE_2_OF_2_OWNER_A;
        SafeLikeErc1271Signer model = new SafeLikeErc1271Signer(owners, 1);
        bytes32 expectedForModel = keccak256(
            abi.encodePacked(
                bytes1(0x19),
                bytes1(0x01),
                keccak256(abi.encode(domainTypehash, block.chainid, address(model))),
                keccak256(abi.encode(safeMsgTypehash, keccak256(abi.encode(ZONE_DIGEST))))
            )
        );
        assertEq(model.getMessageHash(abi.encode(ZONE_DIGEST)), expectedForModel, "model implements the same formula");
    }

    function _recoverSingle(bytes memory signature, bytes32 signedHash) internal pure returns (address) {
        return _recoverAt(signature, 0, signedHash);
    }

    function _recoverAt(bytes memory signature, uint256 index, bytes32 signedHash) internal pure returns (address) {
        return ZoneAuthorizationFixture.recoverOwnerAt(signature, index, signedHash);
    }

    /// @dev Pins the SafeMessage re-wrap itself: the Safe does NOT check signatures against the
    /// hash it is handed. This single fact is why fabrica-v3-api cannot authenticate to a Safe.
    function testFork_safeReWrapsTheZoneDigestIntoItsOwnDomain() public view {
        bytes32 wrapped = ISafe(SAFE_2_OF_2).getMessageHash(abi.encode(ZONE_DIGEST));
        assertEq(wrapped, SAFE_MESSAGE_HASH_2_OF_2, "2-of-2 SafeMessage hash");
        assertTrue(wrapped != ZONE_DIGEST, "the re-wrapped hash must differ from the zone digest");
        bytes32 wrapped1 = ISafe(SAFE_1_OF_1).getMessageHash(abi.encode(ZONE_DIGEST));
        assertEq(wrapped1, SAFE_MESSAGE_HASH_1_OF_1, "1-of-1 SafeMessage hash");
        assertTrue(wrapped1 != wrapped, "each Safe wraps into its own domain");
    }

    function testFork_safeValidatesTheTwoOfTwoSignature() public view {
        assertEq(
            ISafe(SAFE_2_OF_2).isValidSignature(ZONE_DIGEST, SIG_2OF2_VALID),
            bytes4(0x1626ba7e),
            "Safe must return the ERC-1271 magic value"
        );
    }

    /// @dev Re-derives the authorization Seaport itself accepted on-chain.
    function testFork_authorizeAndValidateOrderAcceptSafeSignature() public view {
        ZoneParameters memory params = _zoneParameters(SIG_2OF2_VALID);
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

    /// @dev Raw post-fill state at block 11_488_390, after tx 0xbec9380c...dc9ddc
    /// fulfilled the order for 0.001 ether.
    function testFork_fulfilledOrderStateMatchesDocumentedSettlement() public view {
        assertEq(IERC1155Balance(FABRICA_TOKEN).balanceOf(SELLER, TOKEN_ID), 999, "seller token balance");
        assertEq(IERC1155Balance(FABRICA_TOKEN).balanceOf(BUYER, TOKEN_ID), 1, "buyer token balance");
        assertEq(SELLER.balance, SELLER_ETH_BALANCE_AT_FORK, "seller ETH balance");
        assertEq(BUYER.balance, BUYER_ETH_BALANCE_AT_FORK, "buyer ETH balance");

        (bool isValidated, bool isCancelled, uint256 totalFilled, uint256 totalSize) =
            ISeaportOrderStatus(SEAPORT_1_6).getOrderStatus(ORDER_HASH);
        assertTrue(isValidated, "order status must be marked validated after fulfillment");
        assertFalse(isCancelled, "order must not be cancelled");
        assertEq(totalFilled, 1, "Seaport filled amount");
        assertEq(totalSize, 1, "Seaport order size");
    }

    /// @dev Threshold is enforced through the zone. NOTE this reverts on Safe's LENGTH precheck
    /// (`signatures.length >= threshold * 65`), before any signature is examined — which is
    /// exactly why it cannot stand in for the domain-mismatch controls below.
    function testFork_rejectsSignatureBelowThreshold() public {
        _expectBothEntryPointsRevert(_truncateToOneSignature(SIG_2OF2_VALID), "GS020");
    }

    /// @dev THE domain-mismatch control at threshold 2: correct length, so the length gate does
    /// not fire and owner recovery actually runs.
    function testFork_rejectsCorrectLengthSignatureOverRawZoneDigest() public {
        _expectBothEntryPointsRevert(SIG_2OF2_OVER_RAW_DIGEST, "GS026");
    }

    /// @dev Well-formed signatures over the correct hash, from keys that are not owners.
    function testFork_rejectsWellFormedNonOwnerSignatures() public {
        _expectBothEntryPointsRevert(SIG_2OF2_NON_OWNERS, "GS026");
    }

    /// @dev A real, valid 2-of-2 authorization for a different order does not authorize this one.
    function testFork_rejectsValidAuthorizationBoundToAnotherOrder() public {
        _expectBothEntryPointsRevert(SIG_2OF2_FOR_OTHER_ORDER, "GS026");
    }

    function testFork_rejectsTamperedSignature() public {
        bytes memory tampered = SIG_2OF2_VALID;
        tampered[10] = bytes1(uint8(tampered[10]) ^ 0xFF);
        _expectBothEntryPointsRevert(tampered, "GS026");
    }

    /// @dev The 1-of-1 control pair. Both blobs are 65 bytes, from the same owner, against the
    /// same Safe — the ONLY difference is which hash was signed. Together they prove that the
    /// failure is the SafeMessage domain wrap and not signature length, which is what lets the
    /// item-2 hand-off say "no Safe works, 1-of-1 included".
    function testFork_1of1SafeAcceptsSignatureOverItsOwnMessageHash() public view {
        assertEq(
            ISafe(SAFE_1_OF_1).isValidSignature(ZONE_DIGEST, SIG_1OF1_VALID),
            bytes4(0x1626ba7e),
            "1-of-1 Safe must accept a signature over its SafeMessage hash"
        );
    }

    function testFork_1of1SafeRejectsSignatureOverRawZoneDigest() public {
        assertEq(SIG_1OF1_VALID.length, SIG_1OF1_OVER_RAW_DIGEST.length, "controls must be the same length");
        vm.expectRevert(bytes("GS026"));
        ISafe(SAFE_1_OF_1).isValidSignature(ZONE_DIGEST, SIG_1OF1_OVER_RAW_DIGEST);
    }

    /// @dev Both zone entry points run the same `_verify` guard, so every negative case is
    /// asserted against both — a divergence between them would otherwise go uncaught.
    function _expectBothEntryPointsRevert(bytes memory signature, string memory reason) internal {
        ZoneParameters memory params = _zoneParameters(signature);
        vm.expectRevert(bytes(reason));
        FabricaMarketplaceZone(ZONE).authorizeOrder(params);
        vm.expectRevert(bytes(reason));
        FabricaMarketplaceZone(ZONE).validateOrder(params);
    }

    function _truncateToOneSignature(bytes memory signature) internal pure returns (bytes memory) {
        bytes memory one = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            one[i] = signature[i];
        }
        return one;
    }

    function _zoneParameters(bytes memory signature) internal pure returns (ZoneParameters memory) {
        return ZoneAuthorizationFixture.buildZoneParameters(
            ORDER_HASH,
            ZoneAuthorizationFixture.buildExtraData(EXPIRY, DEFINITION_URL, DISCLOSURE_PACKAGE_ID, signature),
            FABRICA_TOKEN,
            TOKEN_ID,
            0,
            0
        );
    }
}
