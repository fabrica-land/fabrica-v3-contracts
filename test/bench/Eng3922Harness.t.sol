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

    /// @dev The survey's §3 shape plus the `uint64 cycle` Tim's 18:21Z closed-cycle rule
    ///      requires: without it an EAS valuation names no cycle and nothing can be checked.
    string internal constant PRICE_SCHEMA_DEF =
        "uint256 tokenId,uint8 sourceId,uint128 priceUsdc6,uint24 confidence,uint64 cycle,bytes32 inputsHash";
    string internal constant ATTRIBUTE_SCHEMA_DEF = "uint256 tokenId,bytes32 attributeId,bytes32 value";
    string internal constant LOCK_SCHEMA_DEF = "uint256 tokenId,bool locked";
    string internal constant COVERAGE_SCHEMA_DEF = "uint256 tokenId,uint64 cycle";
    string internal constant CYCLE_CLOSE_SCHEMA_DEF = "address writer,uint64 cycle,bytes32 root";

    IEAS internal eas = IEAS(EAS);
    ISchemaRegistry internal registry = ISchemaRegistry(SCHEMA_REGISTRY);
    IEASIndexer internal indexer = IEASIndexer(EAS_INDEXER);

    bytes32 internal priceSchema;
    bytes32 internal attributeSchema;
    bytes32 internal lockSchema;
    bytes32 internal cycleCloseSchema;
    bytes32 internal coverageSchema;

    FactPointer internal pointer;
    OwnerlessFactStore internal ownerlessStore;

    address[3] internal writers;
    /// @notice writer => tokenId => head price uid, mirroring what the oracle writer would keep.
    mapping(address => mapping(uint256 => bytes32)) internal headUid;
    mapping(address => bytes32) internal cycleCloseUid;
    mapping(address => mapping(uint256 => bytes32)) internal coverageUid;

    bool internal forked;

    /// @notice Tokens one weekly cycle covers, so a proof is depth 10 as the rule intends.
    uint256 internal constant TOKENS_PER_CYCLE = 1024;
    /// @notice The coverage rule the headline arm numbers are measured under.
    /// @dev Tim, 3 September 18:47Z: the Merkle-proof idea is out of round 2 and is a round-3
    ///      candidate. Round 2's coverage mechanism is immediate supersession — the lock leg,
    ///      revocation on EAS and the lock flag on the custom store — so the headline numbers
    ///      carry no on-chain coverage check. The other three modes stay measured and are
    ///      reported as a not-in-round-2 appendix, because round 3 will want them.
    BenchAggregatorBase.CoverageMode internal constant COVERAGE = BenchAggregatorBase.CoverageMode.None;

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
        cycleCloseSchema = registry.register(CYCLE_CLOSE_SCHEMA_DEF, address(0), true);
        coverageSchema = registry.register(COVERAGE_SCHEMA_DEF, address(0), true);
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

    function _priceData(uint256 tokenId, uint8 sourceId, uint128 priceUsdc6, uint64 cycle)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            tokenId, sourceId, priceUsdc6, uint24(9000), cycle, keccak256(abi.encode("inputs", tokenId, sourceId))
        );
    }

    /// @notice One EAS price attestation, chained to the previous one by `refUID`, plus the
    ///         pointer write and the supersession revoke that the writer's discipline requires.
    function _easPublish(uint8 sourceId, uint256 tokenId, uint128 priceUsdc6, uint64 cycle)
        internal
        returns (bytes32 uid)
    {
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
                    data: _priceData(tokenId, sourceId, priceUsdc6, cycle),
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
    function _easCycleClose(uint8 sourceId, uint64 cycle, bytes32 root) internal returns (bytes32 uid) {
        address w = writers[sourceId];
        bytes32 prev = cycleCloseUid[w];
        vm.startPrank(w);
        uid = eas.attest(
            AttestationRequest({
                schema: cycleCloseSchema,
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
        pointer.point(0, keccak256("cycleClose"), uid);
        indexer.indexAttestation(uid);
        vm.stopPrank();
        cycleCloseUid[w] = uid;
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
            _easPublish(s, tokenId, 100_000e6, cycle);
            _ownerlessPublish(s, tokenId, 100_000e6, cycle);
            _round1Publish(s, tokenId, 100_000e6, cycle);
        }
        vm.warp(block.timestamp + SEASONING_WINDOW + 1 hours);
        for (uint256 i; i < inWindowWrites; ++i) {
            vm.warp(block.timestamp + 1 hours);
            cycle = nextCycle++;
            uint128 p = uint128(100_000e6 + (i + 1) * 1_000e6);
            for (uint8 s; s < 3; ++s) {
                _easPublish(s, tokenId, p, cycle);
                _ownerlessPublish(s, tokenId, p, cycle);
                _round1Publish(s, tokenId, p, cycle);
            }
        }
        uint256[] memory one = new uint256[](1);
        one[0] = tokenId;
        for (uint8 s; s < 3; ++s) {
            _easCycleClose(s, cycle, cycleRoot);
            vm.startPrank(writers[s]);
            ownerlessStore.heartbeat(cycle, cycleRoot);
            ownerlessStore.stampCoverage(one, cycle);
            pointer.stampCoverage(one, cycle);
            coverageUid[writers[s]][tokenId] = eas.attest(
                AttestationRequest({
                    schema: coverageSchema,
                    data: AttestationRequestData({
                        recipient: address(uint160(tokenId)),
                        expirationTime: 0,
                        revocable: true,
                        refUID: bytes32(0),
                        data: abi.encode(tokenId, cycle),
                        value: 0
                    })
                })
            );
            indexer.indexAttestation(coverageUid[writers[s]][tokenId]);
            vm.stopPrank();
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
        return _cfg(COVERAGE);
    }

    function _cfg(BenchAggregatorBase.CoverageMode mode) internal pure returns (BenchAggregatorBase.AggConfig memory) {
        return BenchAggregatorBase.AggConfig({
            usdc: SEPOLIA_USDC,
            seasoningWindow: SEASONING_WINDOW,
            maxJumpBps: MAX_JUMP_BPS,
            maxDispersionBps: MAX_DISPERSION_BPS,
            minLiveSources: MIN_LIVE_SOURCES,
            maxSilence: MAX_SILENCE,
            coverage: mode
        });
    }

    function _easCfg(bool hb) internal view returns (EasArmBase.EasConfig memory) {
        return EasArmBase.EasConfig({
            eas: EAS,
            priceSchema: priceSchema,
            cycleCloseSchema: cycleCloseSchema,
            coverageSchema: coverageSchema,
            requireHeartbeat: hb,
            writers: writers
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
            h[s] = cycleCloseUid[writers[s]];
        }
        bytes32[3] memory cv;
        for (uint8 s; s < 3; ++s) {
            cv[s] = coverageUid[writers[s]][tokenId];
        }
        bytes32[] memory path = MerkleCycle.proof(cycleLevels, cycleIndexOfToken);
        bytes32[][] memory proofs = new bytes32[][](3);
        for (uint8 s; s < 3; ++s) {
            proofs[s] = path;
        }
        return abi.encode(p, h, cv, proofs);
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

    function _armCustom() internal returns (ArmCustomStore) {
        return _newArmCustom();
    }

    function _newArmCustom() internal returns (ArmCustomStore) {
        return _newArmCustom(COVERAGE);
    }

    function _newArmCustom(BenchAggregatorBase.CoverageMode mode) internal returns (ArmCustomStore) {
        return new ArmCustomStore(_cfg(mode), LIVE_FACT_STORE, 1);
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

    /// @notice What each candidate coverage rule costs inside `price()`, per arm.
    /// @dev Tim is choosing between proof-at-read (18:17Z), the closed-cycle check (18:21Z) and
    ///      no on-chain coverage check, because a writer may cover a token in a cycle WITHOUT
    ///      rewriting an unchanged valuation — in which case coverage lives only in the root and
    ///      only a proof shows it. All three are measured so the choice has numbers under it.
    function test_coverageModeCostByArm() public {
        if (!forked) vm.skip(true);
        uint256 tokenId = uint256(keccak256("eng3922-coverage-cost"));
        _seed(tokenId, 0);
        bytes memory ctx = _contextFor(tokenId);
        BenchAggregatorBase.CoverageMode[4] memory modes = [
            BenchAggregatorBase.CoverageMode.None,
            BenchAggregatorBase.CoverageMode.ClosedCycle,
            BenchAggregatorBase.CoverageMode.ProofAtRead,
            BenchAggregatorBase.CoverageMode.CoverageStamp
        ];
        for (uint256 m; m < modes.length; ++m) {
            string memory tag =
                m == 0 ? "none       " : (m == 1 ? "closedCycle" : (m == 2 ? "proofAtRead" : "coverStamp "));
            _cov(
                tag,
                "arm3 ownerless store   ",
                new ArmOwnerlessStore(_cfg(modes[m]), address(ownerlessStore), writers),
                tokenId,
                ctx
            );
            _cov(
                tag,
                "arm2 EAS+pointer       ",
                new ArmEasPointer(_cfg(modes[m]), _easCfg(true), address(pointer)),
                tokenId,
                ctx
            );
            _cov(tag, "arm1C EAS oracleContext", new ArmEasContext(_cfg(modes[m]), _easCfg(true)), tokenId, ctx);
            _cov(
                tag,
                "arm1 all-EAS indexer   ",
                new ArmEasIndexer(_cfg(modes[m]), _easCfg(true), EAS_INDEXER),
                tokenId,
                ctx
            );
            _cov(tag, "cal. round-1 store     ", _newArmCustom(modes[m]), tokenId, ctx);
        }
    }

    function _cov(string memory mode, string memory label, BenchAggregatorBase arm, uint256 tokenId, bytes memory ctx)
        internal
    {
        (bool ok,,,) = arm.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        if (!ok) {
            emit log_named_string(string.concat(label, " coverage=", mode), "not eligible under this rule");
            return;
        }
        emit log_named_uint(string.concat(label, " coverage=", mode, " gas"), _measure(arm, tokenId, ctx));
    }

    // -------------------------------------------------------------------------
    // Write side — per fact, and per weekly cycle at 1,000 tokens
    // -------------------------------------------------------------------------

    /// @notice EAS writes: `attest` at 1, `multiAttest` at 10 and 100, and the revokes.
    /// @dev Tim, 3 September 16:49Z: EAS batches through `multiAttest`/`multiRevoke` grouped by
    ///      schema, which saves only per-transaction overhead because every attestation still
    ///      writes its own record. Measured rather than assumed.
    function test_writeGasEas() public {
        if (!forked) vm.skip(true);
        _buildCycle(uint256(keccak256("eng3922-write-eas")));
        uint256[3] memory sizes = [uint256(1), 10, 100];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 n = sizes[k];
            bytes32[] memory uids = _attestBatch(n, k);
            emit log_named_uint(string.concat("EAS multiAttest n=", vm.toString(n), " per item"), lastBatchGas / n);
            uint256 revokeGas = _revokeBatch(uids, k);
            emit log_named_uint(string.concat("EAS multiRevoke n=", vm.toString(n), " total"), revokeGas);
            emit log_named_uint(string.concat("EAS multiRevoke n=", vm.toString(n), " per item"), revokeGas / n);
            uint256 indexGas = _indexBatch(uids);
            emit log_named_uint(string.concat("EAS indexAttestations n=", vm.toString(n), " total"), indexGas);
            emit log_named_uint(string.concat("EAS indexAttestations n=", vm.toString(n), " per item"), indexGas / n);
        }
    }

    uint256 internal lastBatchGas;

    function _attestBatch(uint256 n, uint256 salt) internal returns (bytes32[] memory uids) {
        AttestationRequestData[] memory data = new AttestationRequestData[](n);
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = uint256(keccak256(abi.encode("eng3922-batch", salt, i)));
            data[i] = AttestationRequestData({
                recipient: address(uint160(tokenId)),
                expirationTime: uint64(block.timestamp) + MAX_SILENCE,
                revocable: true,
                refUID: bytes32(0),
                data: _priceData(tokenId, 0, 100_000e6, 1),
                value: 0
            });
        }
        MultiAttestationRequest[] memory req = new MultiAttestationRequest[](1);
        req[0] = MultiAttestationRequest({schema: priceSchema, data: data});
        vm.cool(EAS);
        vm.prank(writers[0]);
        uint256 before = gasleft();
        uids = eas.multiAttest(req);
        lastBatchGas = before - gasleft();
        emit log_named_uint(string.concat("EAS multiAttest n=", vm.toString(n), " total"), lastBatchGas);
    }

    function _revokeBatch(bytes32[] memory uids, uint256) internal returns (uint256) {
        RevocationRequestData[] memory data = new RevocationRequestData[](uids.length);
        for (uint256 i; i < uids.length; ++i) {
            data[i] = RevocationRequestData({uid: uids[i], value: 0});
        }
        MultiRevocationRequest[] memory req = new MultiRevocationRequest[](1);
        req[0] = MultiRevocationRequest({schema: priceSchema, data: data});
        vm.cool(EAS);
        vm.prank(writers[0]);
        uint256 before = gasleft();
        eas.multiRevoke(req);
        return before - gasleft();
    }

    function _indexBatch(bytes32[] memory uids) internal returns (uint256) {
        vm.cool(EAS_INDEXER);
        vm.prank(writers[0]);
        uint256 before = gasleft();
        indexer.indexAttestations(uids);
        return before - gasleft();
    }

    /// @notice The ownerless pointer's writes, single and batched.
    function test_writeGasPointer() public {
        if (!forked) vm.skip(true);
        uint256[3] memory sizes = [uint256(1), 10, 100];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 n = sizes[k];
            uint256[] memory ids = new uint256[](n);
            bytes32[] memory kinds = new bytes32[](n);
            bytes32[] memory uids = new bytes32[](n);
            for (uint256 i; i < n; ++i) {
                ids[i] = uint256(keccak256(abi.encode("eng3922-ptr", k, i)));
                kinds[i] = keccak256("price");
                uids[i] = keccak256(abi.encode("uid", k, i));
            }
            vm.cool(address(pointer));
            vm.prank(writers[0]);
            uint256 before = gasleft();
            pointer.pointBatch(ids, kinds, uids);
            uint256 used = before - gasleft();
            emit log_named_uint(string.concat("pointer pointBatch n=", vm.toString(n), " total"), used);
            emit log_named_uint(string.concat("pointer pointBatch n=", vm.toString(n), " per item"), used / n);
        }
    }

    /// @notice The ownerless store's writes, single and the batched prototype.
    /// @dev The batched write is a round-3 candidate (proposal Part A item 12), measured here
    ///      because ENG-3922's measurement list asks for it. It is not proposed for round 2.
    function test_writeGasOwnerlessStore() public {
        if (!forked) vm.skip(true);
        uint256[3] memory sizes = [uint256(1), 10, 100];
        for (uint256 k; k < sizes.length; ++k) {
            uint256 n = sizes[k];
            uint256[] memory ids = new uint256[](n);
            uint128[] memory prices = new uint128[](n);
            uint24[] memory confs = new uint24[](n);
            uint64[] memory valuedAts = new uint64[](n);
            for (uint256 i; i < n; ++i) {
                ids[i] = uint256(keccak256(abi.encode("eng3922-own", k, i)));
                prices[i] = 100_000e6;
                confs[i] = 9000;
                valuedAts[i] = uint64(block.timestamp);
            }
            vm.cool(address(ownerlessStore));
            vm.prank(writers[0]);
            uint256 before = gasleft();
            ownerlessStore.writePriceBatch(ids, prices, confs, valuedAts, 1, keccak256("root"));
            uint256 used = before - gasleft();
            emit log_named_uint(string.concat("ownerless writePriceBatch n=", vm.toString(n), " total"), used);
            emit log_named_uint(string.concat("ownerless writePriceBatch n=", vm.toString(n), " per item"), used / n);
        }
        // Single write, first and repeat, for the per-fact figure the cycle budget uses.
        uint256 tokenId = uint256(keccak256("eng3922-own-single"));
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        uint256 g0 = gasleft();
        ownerlessStore.writePrice(tokenId, 100_000e6, 9000, uint64(block.timestamp), 1);
        emit log_named_uint("ownerless writePrice, first write", g0 - gasleft());
        vm.warp(block.timestamp + 1 hours);
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        g0 = gasleft();
        ownerlessStore.writePrice(tokenId, 101_000e6, 9000, uint64(block.timestamp), 2);
        emit log_named_uint("ownerless writePrice, repeat write", g0 - gasleft());
        // Heartbeat carrying the cycle Merkle root (proposal item 13, now in round 2).
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        g0 = gasleft();
        ownerlessStore.heartbeat(3, keccak256("cycle-root"));
        emit log_named_uint("ownerless heartbeat WITH Merkle root", g0 - gasleft());
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        g0 = gasleft();
        ownerlessStore.heartbeat(4, bytes32(0));
        emit log_named_uint("ownerless heartbeat without root", g0 - gasleft());
    }

    // -------------------------------------------------------------------------
    // Behaviour: the lock, and the keying gap
    // -------------------------------------------------------------------------

    /// @notice Ticket bullet 3 — the lock end to end, on every arm.
    /// @dev A finding worth stating plainly: with three oracle sources and `minLiveSources` 2,
    ///      ONE writer's lock does NOT stop pricing — it drops the live count from 3 to 2, which
    ///      is still the floor. The ticket's expectation that one lock trips
    ///      `CheckFailed(CHECK_MIN_SOURCES)` holds only when two sources were live to begin with.
    ///      Both steps are asserted here so the mechanism is demonstrated rather than argued.
    function test_lockEndToEnd() public {
        if (!forked) vm.skip(true);
        uint256 tokenId = uint256(keccak256("eng3922-lock"));
        _seed(tokenId, 0);
        bytes memory ctx = _contextFor(tokenId);

        ArmOwnerlessStore own = _armOwnerless();
        (bool ok,,,) = own.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        assertTrue(ok, "arm3 prices before any lock");
        vm.prank(writers[0]);
        ownerlessStore.setLock(tokenId, true);
        (ok,,,) = own.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        assertTrue(ok, "arm3 still prices on two live oracle sources after one lock");
        vm.prank(writers[1]);
        ownerlessStore.setLock(tokenId, true);
        bytes32 failed;
        (ok, failed,,) = own.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        assertFalse(ok, "arm3 refuses once a second writer locks");
        assertEq(failed, own.CHECK_MIN_SOURCES(), "arm3 fails on min sources");
        _expectMinSourcesRevert(own, tokenId, ctx);
        emit log_string("arm3 ownerless store: writer lock drops liveCount and price() reverts CHECK_MIN_SOURCES");

        // On EAS the lock IS revocation of the head price attestation, attester-only.
        ArmEasPointer ptr = _armPointer(true);
        (ok,,,) = ptr.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        assertTrue(ok, "arm2 prices before any revocation");
        _revokeHead(0, tokenId);
        (ok,,,) = ptr.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        assertTrue(ok, "arm2 still prices on two live oracle sources after one revocation");
        _revokeHead(1, tokenId);
        (ok, failed,,) = ptr.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        assertFalse(ok, "arm2 refuses once a second writer revokes");
        assertEq(failed, ptr.CHECK_MIN_SOURCES(), "arm2 fails on min sources");
        _expectMinSourcesRevert(ptr, tokenId, ctx);
        emit log_string("arm2 EAS+pointer: writer revocation drops liveCount and price() reverts CHECK_MIN_SOURCES");

        // Option C reads the same revoked attestations through oracleContext and refuses too.
        ArmEasContext cxt = _armContext(true);
        (ok, failed,,) = cxt.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        assertFalse(ok, "arm1C refuses the revoked head even when the caller supplies its uid");
        assertEq(failed, cxt.CHECK_MIN_SOURCES(), "arm1C fails on min sources");
        emit log_string("arm1C oracleContext: a caller-supplied revoked uid is rejected by validation");
    }

    function _revokeHead(uint8 sourceId, uint256 tokenId) internal {
        vm.prank(writers[sourceId]);
        eas.revoke(
            RevocationRequest({
                schema: priceSchema, data: RevocationRequestData({uid: headUid[writers[sourceId]][tokenId], value: 0})
            })
        );
    }

    function _expectMinSourcesRevert(BenchAggregatorBase arm, uint256 tokenId, bytes memory ctx) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256[] memory qty = new uint256[](1);
        qty[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(BenchAggregatorBase.CheckFailed.selector, arm.CHECK_MIN_SOURCES()));
        arm.price(SEPOLIA_COLLATERAL, SEPOLIA_USDC, ids, qty, ctx);
    }

    /// @notice Ticket bullet 2 — the keying gap is closed, and no writer can touch another's row.
    function test_keyingGapClosed() public {
        if (!forked) vm.skip(true);
        uint256 tokenId = uint256(keccak256("eng3922-keying"));
        _seed(tokenId, 0);

        // Pointer: a row is addressed by msg.sender, so writer 1 writing cannot move writer 0's.
        bytes32 before = pointer.headOf(writers[0], tokenId, keccak256("price"));
        vm.prank(writers[1]);
        pointer.point(tokenId, keccak256("price"), keccak256("forged"));
        assertEq(pointer.headOf(writers[0], tokenId, keccak256("price")), before, "writer 0's pointer row is untouched");
        assertEq(
            pointer.headOf(writers[1], tokenId, keccak256("price")),
            keccak256("forged"),
            "writer 1 moved only its own row"
        );

        // Ownerless store: same property on the fact itself.
        OwnerlessFactStore.Fact memory f0 = ownerlessStore.getFact(writers[0], tokenId);
        vm.prank(writers[1]);
        ownerlessStore.writePrice(tokenId, 123_456e6, 9000, uint64(block.timestamp), nextCycle++);
        OwnerlessFactStore.Fact memory f0After = ownerlessStore.getFact(writers[0], tokenId);
        assertEq(f0After.priceUsdc6, f0.priceUsdc6, "writer 0's fact is untouched");
        assertEq(ownerlessStore.getFact(writers[1], tokenId).priceUsdc6, 123_456e6, "writer 1 wrote only its own");

        // EAS: the attester is msg.sender and only the attester may revoke.
        vm.prank(writers[1]);
        vm.expectRevert();
        eas.revoke(
            RevocationRequest({
                schema: priceSchema, data: RevocationRequestData({uid: headUid[writers[0]][tokenId], value: 0})
            })
        );
        emit log_string("keying gap closed on all arms: pointer rows, store facts and EAS revocation are all msg.sender-bound");

        // And the deterministic lookup really is (writer, tokenId, kind).
        for (uint8 sid; sid < 3; ++sid) {
            assertEq(
                pointer.headOf(writers[sid], tokenId, keccak256("price")),
                sid == 1 ? keccak256("forged") : headUid[writers[sid]][tokenId],
                "pointer lookup is deterministic per writer"
            );
        }
    }

    /// @notice Coverage-stamp write cost, and what a weekly cycle at 1,000 tokens costs at
    ///         20%, 50% and 100% movers.
    /// @dev A mover pays a full write; a non-mover pays a stamp. Per-item figures come from a
    ///      100-item batch, which is the regime a 1,000-token cycle actually runs in.
    function test_writeGasCoverageStamp() public {
        if (!forked) vm.skip(true);
        uint256 n = 100;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = uint256(keccak256(abi.encode("eng3922-stamp", i)));
        }

        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        ownerlessStore.stampCoverage(ids, 1);
        uint256 storeStamp = (g - gasleft()) / n;
        emit log_named_uint("ownerless store stampCoverage per token (batch 100)", storeStamp);

        vm.cool(address(pointer));
        vm.prank(writers[0]);
        g = gasleft();
        pointer.stampCoverage(ids, 1);
        uint256 ptrStamp = (g - gasleft()) / n;
        emit log_named_uint("pointer stampCoverage per token (batch 100)", ptrStamp);

        AttestationRequestData[] memory data = new AttestationRequestData[](n);
        for (uint256 i; i < n; ++i) {
            data[i] = AttestationRequestData({
                recipient: address(uint160(ids[i])),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: abi.encode(ids[i], uint64(1)),
                value: 0
            });
        }
        MultiAttestationRequest[] memory req = new MultiAttestationRequest[](1);
        req[0] = MultiAttestationRequest({schema: coverageSchema, data: data});
        vm.cool(EAS);
        vm.prank(writers[0]);
        g = gasleft();
        eas.multiAttest(req);
        uint256 easStamp = (g - gasleft()) / n;
        emit log_named_uint("EAS coverage attestation per token (multiAttest 100)", easStamp);

        // Full-write per-token costs at batch 100, for the mover side of the mix.
        uint256 storeFull = _fullWritePerItem();
        emit log_named_uint("ownerless store full writePrice per token (batch 100)", storeFull);
        uint256 easFull = _easFullPerItem();
        emit log_named_uint("EAS full price attestation per token (multiAttest 100)", easFull);

        uint256[3] memory movers = [uint256(20), 50, 100];
        for (uint256 i; i < movers.length; ++i) {
            uint256 m = movers[i];
            uint256 nonMovers = 100 - m;
            // 1,000 tokens x 3 oracle sources = 3,000 facts per cycle.
            uint256 storeCycle = 30 * (m * storeFull + nonMovers * storeStamp);
            uint256 easPtrCycle = 30 * (m * (easFull + _pointerWritePerItem()) + nonMovers * ptrStamp);
            uint256 easOnlyCycle = 30 * (m * easFull + nonMovers * easStamp);
            emit log_named_uint(
                string.concat("cycle gas, 1000 tokens, ", vm.toString(m), "% movers - arm3 ownerless store"), storeCycle
            );
            emit log_named_uint(
                string.concat("cycle gas, 1000 tokens, ", vm.toString(m), "% movers - arm2 EAS+pointer"), easPtrCycle
            );
            emit log_named_uint(
                string.concat("cycle gas, 1000 tokens, ", vm.toString(m), "% movers - arm1 all-EAS"), easOnlyCycle
            );
        }
    }

    function _fullWritePerItem() internal returns (uint256) {
        uint256 n = 100;
        uint256[] memory ids = new uint256[](n);
        uint128[] memory prices = new uint128[](n);
        uint24[] memory confs = new uint24[](n);
        uint64[] memory valuedAts = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = uint256(keccak256(abi.encode("eng3922-full", i)));
            prices[i] = 100_000e6;
            confs[i] = 9000;
            valuedAts[i] = uint64(block.timestamp);
        }
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        ownerlessStore.writePriceBatch(ids, prices, confs, valuedAts, 1, keccak256("root"));
        return (g - gasleft()) / n;
    }

    function _easFullPerItem() internal returns (uint256) {
        uint256 n = 100;
        AttestationRequestData[] memory data = new AttestationRequestData[](n);
        for (uint256 i; i < n; ++i) {
            uint256 tokenId = uint256(keccak256(abi.encode("eng3922-easfull", i)));
            data[i] = AttestationRequestData({
                recipient: address(uint160(tokenId)),
                expirationTime: 0,
                revocable: true,
                refUID: bytes32(0),
                data: _priceData(tokenId, 0, 100_000e6, 1),
                value: 0
            });
        }
        MultiAttestationRequest[] memory req = new MultiAttestationRequest[](1);
        req[0] = MultiAttestationRequest({schema: priceSchema, data: data});
        vm.cool(EAS);
        vm.prank(writers[0]);
        uint256 g = gasleft();
        eas.multiAttest(req);
        return (g - gasleft()) / n;
    }

    function _pointerWritePerItem() internal returns (uint256) {
        uint256 n = 100;
        uint256[] memory ids = new uint256[](n);
        bytes32[] memory kinds = new bytes32[](n);
        bytes32[] memory uids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = uint256(keccak256(abi.encode("eng3922-ptrw", i)));
            kinds[i] = keccak256("price");
            uids[i] = keccak256(abi.encode("u", i));
        }
        vm.cool(address(pointer));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        pointer.pointBatch(ids, kinds, uids);
        return (g - gasleft()) / n;
    }

    /// @notice The cycle-close write on every arm, with and without the Merkle root.
    /// @dev Round 2's cycle close carries the cycle number only (Tim, 18:47Z). The root-carrying
    ///      variant is measured too because item 13 is a round-3 candidate.
    function test_writeGasCycleClose() public {
        if (!forked) vm.skip(true);
        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        uint256 g = gasleft();
        ownerlessStore.heartbeat(1, bytes32(0));
        emit log_named_uint("arm3 ownerless store, cycle close WITHOUT root", g - gasleft());

        vm.cool(address(ownerlessStore));
        vm.prank(writers[0]);
        g = gasleft();
        ownerlessStore.heartbeat(2, keccak256("root"));
        emit log_named_uint("arm3 ownerless store, cycle close WITH root (round-3 item 13)", g - gasleft());

        // On EAS a cycle close is an attestation. Without the root the payload is two words
        // rather than three.
        vm.cool(EAS);
        vm.prank(writers[0]);
        g = gasleft();
        eas.attest(
            AttestationRequest({
                schema: cycleCloseSchema,
                data: AttestationRequestData({
                    recipient: writers[0],
                    expirationTime: 0,
                    revocable: true,
                    refUID: bytes32(0),
                    data: abi.encode(writers[0], uint64(1), bytes32(0)),
                    value: 0
                })
            })
        );
        emit log_named_uint("EAS arms, cycle close attestation WITHOUT root (zero root word)", g - gasleft());

        vm.cool(EAS);
        vm.prank(writers[0]);
        g = gasleft();
        eas.attest(
            AttestationRequest({
                schema: cycleCloseSchema,
                data: AttestationRequestData({
                    recipient: writers[0],
                    expirationTime: 0,
                    revocable: true,
                    refUID: bytes32(0),
                    data: abi.encode(writers[0], uint64(2), keccak256("root")),
                    value: 0
                })
            })
        );
        emit log_named_uint("EAS arms, cycle close attestation WITH root (round-3 item 13)", g - gasleft());
    }
}
