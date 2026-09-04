// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IEAS, ISchemaRegistry, IEASIndexer, SchemaRecord} from "./eas/IEAS.sol";
import {FactPointer} from "./FactPointer.sol";
import {OwnerlessFactStore} from "./OwnerlessFactStore.sol";
import {BenchAggregatorBase} from "./BenchAggregatorBase.sol";
import {EasArmBase} from "./arms/EasArmBase.sol";
import {ArmEasPointer} from "./arms/ArmEasPointer.sol";
import {ArmEasIndexer} from "./arms/ArmEasIndexer.sol";
import {ArmEasContext} from "./arms/ArmEasContext.sol";
import {ArmOwnerlessStore} from "./arms/ArmOwnerlessStore.sol";
import {PriceGasProbe} from "./PriceGasProbe.sol";

/// @notice ENG-3922 — deploy the harness on Sepolia.
/// @dev As-shipped functional verification: real transactions, real EAS v0.26, real reads. No
///      round-1 contract is touched. Writers are lane-local throwaway EOAs, deliberately NOT the
///      shared deployer, so this never contends for a nonce with the ENG-3895 cycle-close cron.
///
///      Publication is driven separately, not from this script, for a reason worth recording:
///      an EAS uid is `keccak256(schema, recipient, attester, time, expirationTime, revocable,
///      refUID, data, bump)` and therefore depends on the block timestamp of the transaction that
///      creates it. A script cannot compute the uid it is about to create, so it cannot attest
///      and then point at the result in one pass. A real oracle writer has the same constraint:
///      it must attest, read the uids back from the receipt, and point in a second transaction.
///      That is exactly what the driver does, and it is a cost of Option A worth naming.
///
///      Seasoning is deployed at one second rather than 24 hours for the read arms. The
///      seasoning walk's depth is a function of wall-clock age, and nothing can age a Sepolia
///      attestation 24 hours inside one run; at one second the head clears the cutoff on the next
///      block, which is the same code path and the same walk depth (0) the fork measures as the
///      weekly-cycle operating point. The 24-hour behaviour is measured on the fork, where the
///      clock can be held still.
contract Eng3922SepoliaScript is Script {
    address internal constant EAS = 0xC2679fBD37d54388Ce493F1DB75320D236e1815e;
    address internal constant SCHEMA_REGISTRY = 0x0a7E2Ff54e76B8E6659aedc9103FB21c038050D0;
    address internal constant EAS_INDEXER = 0xaEF4103A04090071165F78D45D83A0C0782c2B2a;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    uint64 internal constant SEASONING_ONCHAIN = 1;
    uint64 internal constant MAX_SILENCE = 3 days;
    uint16 internal constant MAX_JUMP_BPS = 5000;
    uint16 internal constant MAX_DISPERSION_BPS = 20_000;
    uint8 internal constant MIN_LIVE_SOURCES = 2;

    string internal constant PRICE_SCHEMA_DEF =
        "uint256 tokenId,uint8 sourceId,uint128 priceUsdc6,uint24 confidence,uint64 cycle,bytes32 inputsHash";
    string internal constant ATTRIBUTE_SCHEMA_DEF = "uint256 tokenId,bytes32 attributeId,bytes32 value";
    string internal constant LOCK_SCHEMA_DEF = "uint256 tokenId,bool locked";
    string internal constant CYCLE_CLOSE_SCHEMA_DEF = "address writer,uint64 cycle,bytes32 root";
    string internal constant COVERAGE_SCHEMA_DEF = "uint256 tokenId,uint64 cycle";

    /// @notice One weekly cycle, per the adoption survey §3: ~20 tokens x 3 oracle sources.
    uint256 internal constant CYCLE_TOKENS = 20;

    IEAS internal eas = IEAS(EAS);
    ISchemaRegistry internal registry = ISchemaRegistry(SCHEMA_REGISTRY);
    IEASIndexer internal indexer = IEASIndexer(EAS_INDEXER);

    uint256[3] internal keys;
    address[3] internal writers;

    function run() external {
        keys[0] = vm.envUint("W0_KEY");
        keys[1] = vm.envUint("W1_KEY");
        keys[2] = vm.envUint("W2_KEY");
        for (uint256 i; i < 3; ++i) {
            writers[i] = vm.addr(keys[i]);
        }

        vm.startBroadcast(keys[0]);
        bytes32 priceSchema = _ensureSchema(PRICE_SCHEMA_DEF);
        bytes32 attributeSchema = _ensureSchema(ATTRIBUTE_SCHEMA_DEF);
        bytes32 lockSchema = _ensureSchema(LOCK_SCHEMA_DEF);
        bytes32 cycleCloseSchema = _ensureSchema(CYCLE_CLOSE_SCHEMA_DEF);
        bytes32 coverageSchema = _ensureSchema(COVERAGE_SCHEMA_DEF);
        FactPointer pointer = new FactPointer();
        OwnerlessFactStore store = new OwnerlessFactStore(48);
        PriceGasProbe probe = new PriceGasProbe();
        BenchAggregatorBase.AggConfig memory cfg = BenchAggregatorBase.AggConfig({
            usdc: SEPOLIA_USDC,
            seasoningWindow: SEASONING_ONCHAIN,
            maxJumpBps: MAX_JUMP_BPS,
            maxDispersionBps: MAX_DISPERSION_BPS,
            minLiveSources: MIN_LIVE_SOURCES,
            maxSilence: MAX_SILENCE,
            // Round 2's configuration: no on-chain coverage check (Tim, 18:47Z). Coverage is
            // immediate supersession, which is the lock leg.
            coverage: BenchAggregatorBase.CoverageMode.None
        });
        EasArmBase.EasConfig memory easCfg = EasArmBase.EasConfig({
            eas: EAS,
            priceSchema: priceSchema,
            cycleCloseSchema: cycleCloseSchema,
            coverageSchema: coverageSchema,
            requireHeartbeat: true,
            writers: writers
        });
        ArmEasPointer armPointer = new ArmEasPointer(cfg, easCfg, address(pointer));
        ArmEasIndexer armIndexer = new ArmEasIndexer(cfg, easCfg, EAS_INDEXER);
        ArmEasContext armContext = new ArmEasContext(cfg, easCfg);
        ArmOwnerlessStore armOwnerless = new ArmOwnerlessStore(cfg, address(store), writers);
        vm.stopBroadcast();

        console2Log("priceSchema", priceSchema);
        console2Log("attributeSchema", attributeSchema);
        console2Log("lockSchema", lockSchema);
        console2Log("cycleCloseSchema", cycleCloseSchema);
        console2Log("coverageSchema", coverageSchema);
        console2Addr("FactPointer", address(pointer));
        console2Addr("OwnerlessFactStore", address(store));
        console2Addr("PriceGasProbe", address(probe));
        console2Addr("ArmEasPointer", address(armPointer));
        console2Addr("ArmEasIndexer", address(armIndexer));
        console2Addr("ArmEasContext", address(armContext));
        console2Addr("ArmOwnerlessStore", address(armOwnerless));
    }

    /// @notice Register a schema, or reuse it when it already exists.
    /// @dev A schema uid is `keccak256(schema, resolver, revocable)`, so re-registering the same
    ///      shape reverts `AlreadyExists()`. Schemas are global and permanent on EAS: a second
    ///      deploy of this harness reuses the first one's schemas rather than making new ones.
    function _ensureSchema(string memory def) internal returns (bytes32 uid) {
        uid = keccak256(abi.encodePacked(def, address(0), true));
        if (registry.getSchema(uid).uid == uid) return uid;
        return registry.register(def, address(0), true);
    }

    function _tokenIdAt(uint256 i) internal pure returns (uint256) {
        return uint256(uint64(uint256(keccak256(abi.encode("eng3922-sepolia-token", i)))));
    }

    /// @notice The audit commitment over the cycle's token ids. Nothing on chain verifies it.
    function _cycleRoot(uint64 cycle) internal pure returns (bytes32) {
        return keccak256(abi.encode("eng3922-cycle-root", cycle, CYCLE_TOKENS));
    }

    function console2Log(string memory k, bytes32 v) internal view {
        console.log(string.concat(k, ": ", vm.toString(v)));
    }

    function console2Addr(string memory k, address v) internal view {
        console.log(string.concat(k, ": ", vm.toString(v)));
    }
}
