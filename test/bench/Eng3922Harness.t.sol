// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    IEAS,
    ISchemaRegistry,
    IEASIndexer,
    Attestation,
    AttestationRequest,
    AttestationRequestData,
    MultiAttestationRequest,
    RevocationRequest,
    RevocationRequestData,
    MultiRevocationRequest
} from "./eas/IEAS.sol";
import {FactPointer} from "./FactPointer.sol";
import {OwnerlessFactStore} from "./OwnerlessFactStore.sol";
import {BenchAggregatorBase} from "./BenchAggregatorBase.sol";
import {ArmEasPointer} from "./arms/ArmEasPointer.sol";
import {ArmEasIndexer} from "./arms/ArmEasIndexer.sol";
import {ArmEasContext} from "./arms/ArmEasContext.sol";
import {ArmOwnerlessStore} from "./arms/ArmOwnerlessStore.sol";
import {ArmCustomStore} from "./arms/ArmCustomStore.sol";
import {EasArmBase} from "./arms/EasArmBase.sol";
import {MerkleCycle} from "./MerkleCycle.sol";
import {FabricaAttributeOracle} from "../../src/FabricaAttributeOracle.sol";

/// @notice ENG-3922 — the fact-layer experiment harness.
/// @dev One aggregator shape, one check-set, five fact-layer arms, measured against the
///      pre-registered mark. Runs on a Sepolia fork against the REAL deployed EAS v0.26 and
///      the REAL deployed round-1 fact store; nothing is mocked and no round-1 contract is
///      modified. The Sepolia deployment script drives the same code for the as-shipped
///      functional verification.
contract Eng3922HarnessTest is Test {
    // Deployed, verified against the on-chain ABIs before use.
    address internal constant EAS = 0xC2679fBD37d54388Ce493F1DB75320D236e1815e;
    address internal constant SCHEMA_REGISTRY = 0x0a7E2Ff54e76B8E6659aedc9103FB21c038050D0;
    address internal constant EAS_INDEXER = 0xaEF4103A04090071165F78D45D83A0C0782c2B2a;
    address internal constant LIVE_FACT_STORE = 0xFfA7535eF090C9193f44399843a05b60808ffC0D;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant SEPOLIA_COLLATERAL = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    uint256 internal constant FORK_BLOCK = 11_628_000;

    // Aggregator configuration. Fede via Tim, 3 September: all three oracle sources, two of
    // three required, MIN of what is available, max silence three days, heartbeat daily.
    // Seasoning is the 24 hours fixed on the 2 September call.
    uint64 internal constant SEASONING_WINDOW = 24 hours;
    uint64 internal constant MAX_SILENCE = 3 days;
    uint16 internal constant MAX_JUMP_BPS = 5000;
    uint16 internal constant MAX_DISPERSION_BPS = 20_000;
    uint8 internal constant MIN_LIVE_SOURCES = 2;

    string internal constant PRICE_SCHEMA_DEF =
        "uint256 tokenId,uint8 sourceId,uint128 priceUsdc6,uint24 confidence,bytes32 inputsHash";
    string internal constant ATTRIBUTE_SCHEMA_DEF = "uint256 tokenId,bytes32 attributeId,bytes32 value";
    string internal constant LOCK_SCHEMA_DEF = "uint256 tokenId,bool locked";
    string internal constant HEARTBEAT_SCHEMA_DEF = "address writer,uint64 cycle,bytes32 root";

    IEAS internal eas = IEAS(EAS);
    ISchemaRegistry internal registry = ISchemaRegistry(SCHEMA_REGISTRY);
    IEASIndexer internal indexer = IEASIndexer(EAS_INDEXER);

    bytes32 internal priceSchema;
    bytes32 internal attributeSchema;
    bytes32 internal lockSchema;
    bytes32 internal heartbeatSchema;

    FactPointer internal pointer;
    OwnerlessFactStore internal ownerlessStore;

    address[3] internal writers;
    /// @notice writer => tokenId => head price uid, mirroring what the oracle writer would keep.
    mapping(address => mapping(uint256 => bytes32)) internal headUid;
    mapping(address => bytes32) internal heartbeatUid;

    bool internal forked;

    /// @notice Tokens one weekly cycle covers, so a proof is depth 10 as the rule intends.
    uint256 internal constant TOKENS_PER_CYCLE = 1024;
    /// @notice Every published arm number is measured with Tim's Merkle rule ON.
    bool internal constant REQUIRE_PROOF = true;

    FabricaAttributeOracle internal round1Store = FabricaAttributeOracle(LIVE_FACT_STORE);
    address internal round1Owner;
    /// @notice Cycle numbers never go backwards: the round-1 store's heartbeat cycle is
    ///         per-validator and monotonic, so one counter spans every token in a run.
    uint64 internal nextCycle;

    bytes32[][] internal cycleLevels;
    bytes32 internal cycleRoot;
    uint256 internal cycleIndexOfToken;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        forked = true;
        writers[0] = makeAddr("oracle-source-prycd");
        writers[1] = makeAddr("oracle-source-openavm");
        writers[2] = makeAddr("oracle-source-regrid");
        priceSchema = registry.register(PRICE_SCHEMA_DEF, address(0), true);
        attributeSchema = registry.register(ATTRIBUTE_SCHEMA_DEF, address(0), true);
        lockSchema = registry.register(LOCK_SCHEMA_DEF, address(0), true);
        heartbeatSchema = registry.register(HEARTBEAT_SCHEMA_DEF, address(0), true);
        pointer = new FactPointer();
        ownerlessStore = new OwnerlessFactStore(48);
        // The calibration arm reads the LIVE round-1 store, so the same prices have to exist
        // there too. Fork-local pranks only; nothing is written to Sepolia by this test.
        round1Owner = round1Store.owner();
        nextCycle = round1Store.lastHeartbeatCycle(1) + 1;
        for (uint8 i; i < 3; ++i) {
            vm.prank(round1Owner);
            round1Store.setPricePublisher(1, writers[i], true);
        }
    }

    // -------------------------------------------------------------------------
    // Publication helpers — what the oracle writer does each cycle
    // -------------------------------------------------------------------------

    function _priceData(uint256 tokenId, uint8 sourceId, uint128 priceUsdc6) internal pure returns (bytes memory) {
        return
            abi.encode(tokenId, sourceId, priceUsdc6, uint24(9000), keccak256(abi.encode("inputs", tokenId, sourceId)));
    }

    /// @notice One EAS price attestation, chained to the previous one by `refUID`, plus the
    ///         pointer write and the supersession revoke that the writer's discipline requires.
    function _easPublish(uint8 sourceId, uint256 tokenId, uint128 priceUsdc6) internal returns (bytes32 uid) {
        address w = writers[sourceId];
        bytes32 prev = headUid[w][tokenId];
        vm.startPrank(w);
        uid = eas.attest(
            AttestationRequest({
                schema: priceSchema,
                data: AttestationRequestData({
                    recipient: address(uint160(tokenId)),
                    expirationTime: uint64(block.timestamp) + MAX_SILENCE,
                    revocable: true,
                    refUID: prev,
                    data: _priceData(tokenId, sourceId, priceUsdc6),
                    value: 0
                })
            })
        );
        if (prev != bytes32(0)) {
            eas.revoke(RevocationRequest({schema: priceSchema, data: RevocationRequestData({uid: prev, value: 0})}));
        }
        pointer.point(tokenId, keccak256("price"), uid);
        // EAS does not index on attest. Arm 1 reads through EAS's `Indexer`, and the Indexer
        // only knows an attestation that someone paid to index. This is a real extra write on
        // the all-EAS arm, and it is measured as one.
        indexer.indexAttestation(uid);
        vm.stopPrank();
        headUid[w][tokenId] = uid;
    }

    /// @notice One heartbeat attestation carrying the cycle's Merkle root (round-2 item 13).
    function _easHeartbeat(uint8 sourceId, uint64 cycle, bytes32 root) internal returns (bytes32 uid) {
        address w = writers[sourceId];
        bytes32 prev = heartbeatUid[w];
        vm.startPrank(w);
        uid = eas.attest(
            AttestationRequest({
                schema: heartbeatSchema,
                data: AttestationRequestData({
                    recipient: w,
                    expirationTime: uint64(block.timestamp) + MAX_SILENCE,
                    revocable: true,
                    refUID: prev,
                    data: abi.encode(w, cycle, root),
                    value: 0
                })
            })
        );
        pointer.point(0, keccak256("heartbeat"), uid);
        indexer.indexAttestation(uid);
        vm.stopPrank();
        heartbeatUid[w] = uid;
    }

    function _ownerlessPublish(uint8 sourceId, uint256 tokenId, uint128 priceUsdc6, uint64 cycle) internal {
        vm.prank(writers[sourceId]);
        ownerlessStore.writePrice(tokenId, priceUsdc6, 9000, uint64(block.timestamp), cycle);
    }

    /// @notice The same publication into the deployed round-1 store, for the calibration arm.
    function _round1Publish(uint8 sourceId, uint256 tokenId, uint128 priceUsdc6, uint64 cycle) internal {
        vm.prank(writers[sourceId]);
        round1Store.writePrice(
            FabricaAttributeOracle.PriceWriteParams({
                validatorId: 1,
                tokenId: tokenId,
                sourceId: sourceId,
                priceUsdc6: priceUsdc6,
                confidenceScore: 9000,
                valuedAt: uint64(block.timestamp),
                cycle: cycle,
                provenance: FabricaAttributeOracle.Provenance({
                    rawPayloadHash: keccak256(abi.encode("raw", tokenId, sourceId, priceUsdc6, block.timestamp)),
                    inputsHash: keccak256(abi.encode("inputs", tokenId, sourceId, priceUsdc6, block.timestamp)),
                    timestamp: uint64(block.timestamp),
                    signer: writers[sourceId]
                })
            })
        );
    }

    /// @notice Publish the same price history on every fact layer, so the arms read like for like.
    /// @param inWindowWrites Republications inside the seasoning window. Zero leaves the current
    ///        price already past the cutoff, which is what a weekly cycle normally looks like.
    function _seed(uint256 tokenId, uint256 inWindowWrites) internal {
        _buildCycle(tokenId);
        vm.prank(round1Owner);
        round1Store.register(1, tokenId);
        uint64 cycle = nextCycle++;
        // The pre-seasoning baseline every arm's seasoning walk lands on.
        for (uint8 s; s < 3; ++s) {
            _easPublish(s, tokenId, 100_000e6);
            _ownerlessPublish(s, tokenId, 100_000e6, cycle);
            _round1Publish(s, tokenId, 100_000e6, cycle);
        }
        vm.warp(block.timestamp + SEASONING_WINDOW + 1 hours);
        for (uint256 i; i < inWindowWrites; ++i) {
            vm.warp(block.timestamp + 1 hours);
            cycle = nextCycle++;
            uint128 p = uint128(100_000e6 + (i + 1) * 1_000e6);
            for (uint8 s; s < 3; ++s) {
                _easPublish(s, tokenId, p);
                _ownerlessPublish(s, tokenId, p, cycle);
                _round1Publish(s, tokenId, p, cycle);
            }
        }
        for (uint8 s; s < 3; ++s) {
            _easHeartbeat(s, cycle, cycleRoot);
            vm.prank(writers[s]);
            ownerlessStore.heartbeat(cycle, cycleRoot);
        }
        // The live store's own maxSilence is one hour, so the calibration arm needs a heartbeat
        // inside that window after the seeding warps.
        vm.prank(writers[0]);
        round1Store.heartbeat(1, cycle);
    }

    // -------------------------------------------------------------------------
    // Arm construction
    // -------------------------------------------------------------------------

    function _cfg() internal pure returns (BenchAggregatorBase.AggConfig memory) {
        return _cfg(REQUIRE_PROOF);
    }

    function _cfg(bool proof) internal pure returns (BenchAggregatorBase.AggConfig memory) {
        return BenchAggregatorBase.AggConfig({
            usdc: SEPOLIA_USDC,
            seasoningWindow: SEASONING_WINDOW,
            maxJumpBps: MAX_JUMP_BPS,
            maxDispersionBps: MAX_DISPERSION_BPS,
            minLiveSources: MIN_LIVE_SOURCES,
            maxSilence: MAX_SILENCE,
            requireMerkleProof: proof
        });
    }

    function _easCfg(bool hb) internal view returns (EasArmBase.EasConfig memory) {
        return EasArmBase.EasConfig({
            eas: EAS, priceSchema: priceSchema, heartbeatSchema: heartbeatSchema, requireHeartbeat: hb, writers: writers
        });
    }

    function _armPointer(bool hb) internal returns (ArmEasPointer) {
        return new ArmEasPointer(_cfg(), _easCfg(hb), address(pointer));
    }

    function _armIndexer(bool hb) internal returns (ArmEasIndexer) {
        return new ArmEasIndexer(_cfg(), _easCfg(hb), EAS_INDEXER);
    }

    function _armContext(bool hb) internal returns (ArmEasContext) {
        return new ArmEasContext(_cfg(), _easCfg(hb));
    }

    function _armOwnerless() internal returns (ArmOwnerlessStore) {
        return new ArmOwnerlessStore(_cfg(), address(ownerlessStore), writers);
    }

    /// @notice Build the cycle's Merkle tree over TOKENS_PER_CYCLE ids, with `tokenId` inside it.
    /// @dev Only `tokenId` has facts published; the other ids exist so the proof has the depth a
    ///      real 1,000-token cycle produces. Depth 10 for 1,024 leaves.
    function _buildCycle(uint256 tokenId) internal {
        uint256[] memory ids = new uint256[](TOKENS_PER_CYCLE);
        cycleIndexOfToken = TOKENS_PER_CYCLE / 2;
        for (uint256 i; i < TOKENS_PER_CYCLE; ++i) {
            ids[i] = i == cycleIndexOfToken ? tokenId : uint256(keccak256(abi.encode("cycle-filler", i)));
        }
        cycleLevels = MerkleCycle.build(ids);
        cycleRoot = MerkleCycle.root(cycleLevels);
    }

    function _contextFor(uint256 tokenId) internal view returns (bytes memory) {
        bytes32[3] memory p;
        bytes32[3] memory h;
        for (uint8 s; s < 3; ++s) {
            p[s] = headUid[writers[s]][tokenId];
            h[s] = heartbeatUid[writers[s]];
        }
        bytes32[] memory path = MerkleCycle.proof(cycleLevels, cycleIndexOfToken);
        bytes32[][] memory proofs = new bytes32[][](3);
        for (uint8 s; s < 3; ++s) {
            proofs[s] = path;
        }
        return abi.encode(p, h, proofs);
    }

    /// @notice Gas inside one single-token, quantity-1 `price()` call, from cold storage.
    function _measure(BenchAggregatorBase arm, uint256 tokenId, bytes memory ctx) internal returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256[] memory qty = new uint256[](1);
        qty[0] = 1;
        vm.cool(EAS);
        vm.cool(EAS_INDEXER);
        vm.cool(LIVE_FACT_STORE);
        vm.cool(address(pointer));
        vm.cool(address(ownerlessStore));
        vm.cool(address(arm));
        uint256 before = gasleft();
        uint256 p = arm.price(SEPOLIA_COLLATERAL, SEPOLIA_USDC, ids, qty, ctx);
        uint256 spent = before - gasleft();
        require(p != 0, "price must be non-zero");
        return spent;
    }

    // -------------------------------------------------------------------------
    // The go/no-go: gas inside `price()` for a three-source read, per arm
    // -------------------------------------------------------------------------

    /// @notice Read gas for every arm at several seasoning walk depths.
    /// @dev Walk depth is REPORTED by the aggregator (`eligibilityReport` returns the hops it
    ///      actually took), not assumed from the seeding, so the arms are compared at equal
    ///      measured depth rather than at equal fixture parameters.
    function test_readGasByArm() public {
        if (!forked) vm.skip(true);
        uint256[4] memory levels = [uint256(0), 1, 3, 7];
        for (uint256 i; i < levels.length; ++i) {
            uint256 tokenId = uint256(keccak256(abi.encode("eng3922-read", levels[i])));
            _seed(tokenId, levels[i]);
            bytes memory ctx = _contextFor(tokenId);
            _report("arm2 EAS+pointer      ", levels[i], _armPointer(true), tokenId, ctx);
            _report("arm1 all-EAS indexer  ", levels[i], _armIndexer(true), tokenId, ctx);
            _report("arm1C EAS oracleContext", levels[i], _armContext(true), tokenId, ctx);
            _report("arm3 ownerless store  ", levels[i], _armOwnerless(), tokenId, ctx);
            _report("cal. round-1 store    ", levels[i], _armCustom(), tokenId, ctx);
        }
    }

    /// @notice The cost of rebuilding EAS's missing per-writer heartbeat, isolated.
    /// @dev EAS has no dead-man switch on the attester. Rebuilding it costs one extra lookup
    ///      plus one `getAttestation` per oracle source per read. Measured rather than caveated.
    function test_readGasHeartbeatCost() public {
        if (!forked) vm.skip(true);
        uint256 tokenId = uint256(keccak256("eng3922-heartbeat-cost"));
        _seed(tokenId, 0);
        bytes memory ctx = _contextFor(tokenId);
        uint256 withHb = _measure(_armPointer(true), tokenId, ctx);
        uint256 withoutHb = _measure(_armPointer(false), tokenId, ctx);
        emit log_named_uint("arm2 price() WITH rebuilt per-writer heartbeat", withHb);
        emit log_named_uint("arm2 price() WITHOUT heartbeat (freshness from attestation time only)", withoutHb);
        emit log_named_uint("cost of rebuilding EAS's missing heartbeat, 3 oracle sources", withHb - withoutHb);
    }

    function _armCustom() internal returns (ArmCustomStore arm) {
        arm = _newArmCustom();
        arm.setCycleRoot(cycleRoot);
    }

    function _newArmCustom() internal returns (ArmCustomStore) {
        return _newArmCustom(REQUIRE_PROOF);
    }

    function _newArmCustom(bool proof) internal returns (ArmCustomStore) {
        return new ArmCustomStore(_cfg(proof), LIVE_FACT_STORE, 1);
    }

    function _report(string memory label, uint256 level, BenchAggregatorBase arm, uint256 tokenId, bytes memory ctx)
        internal
    {
        (bool ok,,, uint256 hops) = arm.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        if (!ok) {
            emit log_named_string(string.concat(label, " seed=", vm.toString(level)), "not eligible on this fact layer");
            return;
        }
        uint256 gasUsed = _measure(arm, tokenId, ctx);
        emit log_named_uint(
            string.concat(label, " seed=", vm.toString(level), " depth/source=", vm.toString(hops / 3), " gas"), gasUsed
        );
    }

    /// @notice What Tim's Merkle rule costs inside `price()`, per arm, as its own line.
    /// @dev Tim, 3 September 18:17Z: a valuation for a token not proven under its writer's root
    ///      is refused. Three proofs of depth 10 for a 1,000-token cycle. Measured by running
    ///      each arm twice — rule on, rule off — with everything else identical.
    function test_merkleProofCostByArm() public {
        if (!forked) vm.skip(true);
        uint256 tokenId = uint256(keccak256("eng3922-proof-cost"));
        _seed(tokenId, 0);
        bytes memory ctx = _contextFor(tokenId);
        uint256 on;
        uint256 off;

        on = _measure(new ArmOwnerlessStore(_cfg(true), address(ownerlessStore), writers), tokenId, ctx);
        off = _measure(new ArmOwnerlessStore(_cfg(false), address(ownerlessStore), writers), tokenId, ctx);
        _proofLine("arm3 ownerless store   ", on, off);

        on = _measure(new ArmEasPointer(_cfg(true), _easCfg(true), address(pointer)), tokenId, ctx);
        off = _measure(new ArmEasPointer(_cfg(false), _easCfg(true), address(pointer)), tokenId, ctx);
        _proofLine("arm2 EAS+pointer       ", on, off);

        on = _measure(new ArmEasContext(_cfg(true), _easCfg(true)), tokenId, ctx);
        off = _measure(new ArmEasContext(_cfg(false), _easCfg(true)), tokenId, ctx);
        _proofLine("arm1C EAS oracleContext", on, off);

        on = _measure(new ArmEasIndexer(_cfg(true), _easCfg(true), EAS_INDEXER), tokenId, ctx);
        off = _measure(new ArmEasIndexer(_cfg(false), _easCfg(true), EAS_INDEXER), tokenId, ctx);
        _proofLine("arm1 all-EAS indexer   ", on, off);

        ArmCustomStore cOn = _newArmCustom(true);
        cOn.setCycleRoot(cycleRoot);
        ArmCustomStore cOff = _newArmCustom(false);
        cOff.setCycleRoot(cycleRoot);
        _proofLine("cal. round-1 store     ", _measure(cOn, tokenId, ctx), _measure(cOff, tokenId, ctx));
    }

    function _proofLine(string memory label, uint256 on, uint256 off) internal {
        emit log_named_uint(string.concat(label, " proof ON  gas"), on);
        emit log_named_uint(string.concat(label, " proof OFF gas"), off);
        emit log_named_uint(string.concat(label, " Merkle rule costs"), on - off);
    }
}
