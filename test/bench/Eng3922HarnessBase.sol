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

/// @notice ENG-3922 — the fact-layer experiment fixture, shared by the measurement suites.
/// @dev One aggregator shape, one check-set, five fact-layer arms, measured against the
///      pre-registered mark. Runs on a Sepolia fork against the REAL deployed EAS v0.26 and
///      the REAL deployed round-1 fact store; nothing is mocked and no round-1 contract is
///      modified. The Sepolia deployment script drives the same code for the as-shipped
///      functional verification.
abstract contract Eng3922HarnessBase is Test {
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

    function setUp() public virtual {
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

    /// @notice The calibration arm: the harness reading the DEPLOYED round-1 fact store.
    /// @dev Its job is to make the harness's own overhead visible rather than assumed. The
    ///      difference between this and the deployed `FabricaOracleAggregator` at the same walk
    ///      depth is the harness tax, and every EAS arm is quoted against this rather than against
    ///      the deployed aggregator, because only this holds everything else equal.
    function _armCustom() internal returns (ArmCustomStore) {
        return _newArmCustom(COVERAGE);
    }

    function _newArmCustom(BenchAggregatorBase.CoverageMode mode) internal returns (ArmCustomStore) {
        return new ArmCustomStore(_cfg(mode), LIVE_FACT_STORE, 1);
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

    // -------------------------------------------------------------------------
    // Measurement
    // -------------------------------------------------------------------------

    /// @notice Gas inside one single-token, quantity-1 `price()` call, from cold storage.
    /// @dev Per the CLAUDE.md gas guard, exactly ONE of these runs per test function, and the
    ///      cooling is applied immediately before the measured call. `price()` is quoted as
    ///      execution gas because a pool calls it inside its own transaction and it is never sent
    ///      as one; that is the ticket's "gas inside `price()`".
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

    /// @notice One measured row: the arm's `price()` gas and the seasoning walk depth it needed.
    function _row(string memory label, BenchAggregatorBase arm, uint256 tokenId, bytes memory ctx) internal {
        (bool ok,,, uint256 hops) = arm.eligibilityReport(SEPOLIA_USDC, tokenId, ctx);
        if (!ok) {
            emit log_named_string(label, "not eligible on this fact layer under this rule");
            return;
        }
        emit log_named_uint(
            string.concat(label, " depth/source=", vm.toString(hops / 3), " price() execution gas"),
            _measure(arm, tokenId, ctx)
        );
    }

    /// @notice 21,000 plus EIP-2028 calldata: 4 gas per zero byte, 16 per non-zero.
    function _intrinsicGas(bytes memory callData) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < callData.length; ++i) {
            g += callData[i] == 0 ? 4 : 16;
        }
    }

    /// @notice Emit a write cost as execution, intrinsic-plus-calldata, and the whole-transaction
    ///         total, per the CLAUDE.md guard's "whole-transaction gas when the number is a cost".
    function _emitCost(string memory label, uint256 execution, bytes memory callData, uint256 items) internal {
        uint256 intrinsic = _intrinsicGas(callData);
        uint256 whole = execution + intrinsic;
        emit log_named_uint(string.concat(label, " -- execution gas"), execution);
        emit log_named_uint(string.concat(label, " -- intrinsic + calldata"), intrinsic);
        emit log_named_uint(string.concat(label, " -- WHOLE TRANSACTION"), whole);
        if (items > 1) {
            emit log_named_uint(string.concat(label, " -- WHOLE TRANSACTION per item"), whole / items);
        }
    }
}
