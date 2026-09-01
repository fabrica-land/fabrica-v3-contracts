// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaAttributeOracle} from "../src/FabricaAttributeOracle.sol";

contract FabricaAttributeOracleTest is Test {
    FabricaAttributeOracle internal oracle;

    address internal owner;
    address internal publisher;
    address internal recoveryWriter;
    address internal stranger;

    uint256 internal constant VALIDATOR = 1;
    uint256 internal constant TOKEN_A = 42;
    uint256 internal constant TOKEN_B = 99;
    uint8 internal constant SRC_PRYCD = 0;
    uint8 internal constant SRC_OPENAVM = 1;
    uint8 internal constant SRC_REGRID = 2;

    uint128 internal constant PRICE_100K = 100_000e6;
    uint128 internal constant PRICE_110K = 110_000e6;
    uint128 internal constant PRICE_50K = 50_000e6;

    event PriceWritten(
        uint256 indexed validatorId,
        uint256 indexed tokenId,
        uint8 indexed sourceId,
        uint128 priceUsdc6,
        uint24 confidenceScore,
        uint64 valuedAt,
        uint64 cycle,
        bytes32 provenanceHash
    );
    event IndexAssigned(uint256 indexed validatorId, uint256 indexed tokenId, uint32 index, uint64 registeredAt);
    event KeeperHeartbeat(uint256 indexed validatorId, uint64 cycle, uint64 timestamp);
    event RecoveryStatusSet(uint256 indexed validatorId, uint256 indexed tokenId, uint8 status, address indexed writer);
    event CycleInvalidated(uint256 indexed validatorId, uint64 minValidCycle);

    function setUp() public {
        vm.warp(1_700_000_000);
        owner = makeAddr("owner");
        publisher = makeAddr("publisher");
        recoveryWriter = makeAddr("recoveryWriter");
        stranger = makeAddr("stranger");
        FabricaAttributeOracle.KnobConfig memory knobs = _defaultKnobs();
        knobs.historyDepth = 8;
        oracle = new FabricaAttributeOracle(owner, knobs);
        vm.startPrank(owner);
        oracle.setPricePublisher(VALIDATOR, publisher, true);
        oracle.setRecoveryWriter(VALIDATOR, recoveryWriter, true);
        oracle.register(VALIDATOR, TOKEN_A);
        vm.stopPrank();
    }

    function test_constructor_rejectsZeroOwner() public {
        FabricaAttributeOracle.KnobConfig memory knobs = _defaultKnobs();
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new FabricaAttributeOracle(address(0), knobs);
    }

    function test_constructor_rejectsZeroHistoryDepth() public {
        FabricaAttributeOracle.KnobConfig memory knobs = _defaultKnobs();
        knobs.historyDepth = 0;
        vm.expectRevert(FabricaAttributeOracle.HistoryDepthZero.selector);
        new FabricaAttributeOracle(owner, knobs);
    }

    function test_defaultKnobs_matchPhase0StartProposals() public view {
        FabricaAttributeOracle.KnobConfig memory knobs = oracle.defaultKnobs();
        assertEq(knobs.maxUpBps, 1500);
        assertEq(knobs.maxDownBps, 5000);
        assertEq(knobs.maxSilence, 24 hours);
        assertEq(knobs.minWriteInterval, 1 hours);
        assertEq(knobs.registrySeasonDelay, 1 days);
        assertEq(knobs.maxFirstPriceUsdc6, 50_000_000e6);
        assertEq(knobs.valueCeilingUsdc6, 50_000_000e6);
        assertEq(knobs.historyDepth, 48);
    }

    function test_renounceOwnership_disabled() public {
        vm.prank(owner);
        vm.expectRevert(FabricaAttributeOracle.OwnershipRenounceDisabled.selector);
        oracle.renounceOwnership();
    }

    function test_setKnobs_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setKnobs(1000, 4000, 1e6, 12 hours, 30 minutes, 12 hours, 1e6);
    }

    function test_setKnobs_rejectsFirstPriceAboveCeiling() public {
        vm.prank(owner);
        vm.expectRevert(FabricaAttributeOracle.InvalidKnob.selector);
        oracle.setKnobs(1500, 5000, 100e6, 24 hours, 1 hours, 1 days, 50e6);
    }

    function test_register_assignsDenseIndexAndSeedsNormal() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IndexAssigned(VALIDATOR, TOKEN_B, 2, uint64(block.timestamp));
        oracle.register(VALIDATOR, TOKEN_B);
        (uint64 registeredAt, uint32 index, bool registered) = oracle.registry(VALIDATOR, TOKEN_B);
        assertTrue(registered);
        assertEq(index, 2);
        assertEq(registeredAt, uint64(block.timestamp));
        assertEq(oracle.recoveryStatusOf(VALIDATOR, TOKEN_B), oracle.RECOVERY_NORMAL());
    }

    function test_register_onlyOwner() public {
        vm.prank(publisher);
        vm.expectRevert();
        oracle.register(VALIDATOR, TOKEN_B);
    }

    function test_register_rejectsDuplicate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.AlreadyRegistered.selector, VALIDATOR, TOKEN_A));
        oracle.register(VALIDATOR, TOKEN_A);
    }

    function test_registerBatch() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = TOKEN_B;
        ids[1] = 1001;
        vm.prank(owner);
        oracle.registerBatch(VALIDATOR, ids);
        (, uint32 indexB,) = oracle.registry(VALIDATOR, TOKEN_B);
        (, uint32 indexC,) = oracle.registry(VALIDATOR, 1001);
        assertEq(indexB, 2);
        assertEq(indexC, 3);
    }

    function test_registrySeasoning() public {
        assertFalse(oracle.isRegistrySeasoned(VALIDATOR, TOKEN_A));
        vm.warp(block.timestamp + 1 days - 1);
        assertFalse(oracle.isRegistrySeasoned(VALIDATOR, TOKEN_A));
        vm.warp(block.timestamp + 1);
        assertTrue(oracle.isRegistrySeasoned(VALIDATOR, TOKEN_A));
    }

    function test_writePrice_threeIndependentSources() public {
        FabricaAttributeOracle.Provenance memory prov = _prov(publisher);
        vm.startPrank(publisher);
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 8000, 1, prov));
        oracle.writePrice(_priceParams(TOKEN_A, SRC_OPENAVM, PRICE_110K, 7000, 1, prov));
        oracle.writePrice(_priceParams(TOKEN_A, SRC_REGRID, PRICE_50K, 0, 1, prov));
        vm.stopPrank();
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).priceUsdc6, PRICE_100K);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_OPENAVM).priceUsdc6, PRICE_110K);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_REGRID).priceUsdc6, PRICE_50K);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).confidenceScore, 8000);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_REGRID).confidenceScore, 0);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).provenance.signer, publisher);
        assertTrue(
            oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).priceUsdc6
                != oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_OPENAVM).priceUsdc6
        );
    }

    function test_writePrice_notPublisher() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.NotPricePublisher.selector, VALIDATOR, stranger));
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, _prov(stranger)));
    }

    function test_writePrice_provenanceSignerMismatch() public {
        FabricaAttributeOracle.Provenance memory prov = _prov(stranger);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaAttributeOracle.ProvenanceSignerMismatch.selector, publisher, stranger)
        );
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, prov));
    }

    function test_writePrice_notRegistered() public {
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.NotRegistered.selector, VALIDATOR, TOKEN_B));
        oracle.writePrice(_priceParams(TOKEN_B, SRC_PRYCD, PRICE_100K, 0, 1, _prov(publisher)));
    }

    function test_writePrice_rejectsZeroPrice() public {
        vm.prank(publisher);
        vm.expectRevert(FabricaAttributeOracle.InvalidPrice.selector);
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, 0, 0, 1, _prov(publisher)));
    }

    function test_writePrice_sourceNotEnabled() public {
        vm.prank(owner);
        oracle.setSourceEnabled(SRC_PRYCD, false);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.SourceNotEnabled.selector, SRC_PRYCD));
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, _prov(publisher)));
    }

    function test_writePrice_emitsPriceWritten() public {
        FabricaAttributeOracle.Provenance memory prov = _prov(publisher);
        bytes32 pHash = keccak256(abi.encode(prov.rawPayloadHash, prov.inputsHash, prov.timestamp, prov.signer));
        vm.prank(publisher);
        vm.expectEmit(true, true, true, true);
        emit PriceWritten(VALIDATOR, TOKEN_A, SRC_PRYCD, PRICE_100K, 100, uint64(block.timestamp), 1, pHash);
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 100, 1, prov));
    }

    function test_writePrice_firstPriceTooHigh() public {
        uint128 tooHigh = 50_000_000e6 + 1;
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaAttributeOracle.FirstPriceTooHigh.selector, tooHigh, 50_000_000e6)
        );
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, tooHigh, 0, 1, _prov(publisher)));
    }

    function test_writePrice_bandUpExceeded() public {
        _write(SRC_PRYCD, PRICE_100K, 1);
        uint128 over = 115_001e6;
        vm.warp(block.timestamp + 1 hours);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaAttributeOracle.BandExceeded.selector, PRICE_100K, over, uint16(1500), uint16(5000)
            )
        );
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, over, 0, 2, _prov(publisher)));
    }

    function test_writePrice_bandDownExceeded() public {
        _write(SRC_PRYCD, PRICE_100K, 1);
        uint128 under = 49_999e6;
        vm.warp(block.timestamp + 1 hours);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaAttributeOracle.BandExceeded.selector, PRICE_100K, under, uint16(1500), uint16(5000)
            )
        );
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, under, 0, 2, _prov(publisher)));
    }

    function test_writePrice_inBandSucceeds() public {
        _write(SRC_PRYCD, PRICE_100K, 1);
        vm.warp(block.timestamp + 1 hours);
        _write(SRC_PRYCD, 115_000e6, 2);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).priceUsdc6, 115_000e6);
    }

    function test_writePrice_minInterval_usesLastWrittenAtNotValuedAt() public {
        // Publisher passes past valuedAt — interval must still use wall-clock lastWrittenAt.
        FabricaAttributeOracle.PriceWriteParams memory params =
            _priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, _prov(publisher));
        params.valuedAt = 1;
        vm.prank(publisher);
        oracle.writePrice(params);
        uint64 lastWrite = uint64(block.timestamp);
        params.priceUsdc6 = PRICE_110K;
        params.cycle = 2;
        params.valuedAt = 1;
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaAttributeOracle.WriteTooSoon.selector, lastWrite, uint64(1 hours), lastWrite)
        );
        oracle.writePrice(params);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(publisher);
        oracle.writePrice(params);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).priceUsdc6, PRICE_110K);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).valuedAt, 1);
    }

    function test_writePrice_rejectsFutureValuedAt() public {
        FabricaAttributeOracle.PriceWriteParams memory params =
            _priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, _prov(publisher));
        params.valuedAt = uint64(block.timestamp + 1);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaAttributeOracle.InvalidValuedAt.selector, params.valuedAt, uint64(block.timestamp)
            )
        );
        oracle.writePrice(params);
    }

    function test_writePrice_valueCeiling() public {
        // maxFirst ≤ ceiling; subsequent in-band write still blocked by ceiling.
        vm.prank(owner);
        oracle.setKnobs(1500, 5000, 80_000e6, 24 hours, 1 hours, 1 days, 90_000e6);
        _write(SRC_PRYCD, 80_000e6, 1);
        vm.warp(block.timestamp + 1 hours);
        uint128 overCeiling = 91_000e6; // ≤ 80k * 1.15 band, > 90k ceiling
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaAttributeOracle.AboveValueCeiling.selector, overCeiling, uint128(90_000e6))
        );
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, overCeiling, 0, 2, _prov(publisher)));
    }

    function test_writePrice_cycleNotMonotonic() public {
        _write(SRC_PRYCD, PRICE_100K, 5);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.CycleNotMonotonic.selector, uint64(5), uint64(4)));
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, PRICE_110K, 0, 4, _prov(publisher)));
    }

    function test_historyRing_retainsPriorValuesNewestFirst() public {
        _write(SRC_PRYCD, PRICE_100K, 1);
        vm.warp(block.timestamp + 1 hours);
        _write(SRC_PRYCD, PRICE_110K, 2);
        vm.warp(block.timestamp + 1 hours);
        _write(SRC_PRYCD, 105_000e6, 3);
        assertEq(oracle.historyLength(VALIDATOR, TOKEN_A, SRC_PRYCD), 2);
        assertEq(oracle.getHistory(VALIDATOR, TOKEN_A, SRC_PRYCD, 0).priceUsdc6, PRICE_110K);
        assertEq(oracle.getHistory(VALIDATOR, TOKEN_A, SRC_PRYCD, 0).cycle, 2);
        assertEq(oracle.getHistory(VALIDATOR, TOKEN_A, SRC_PRYCD, 1).priceUsdc6, PRICE_100K);
        assertEq(oracle.getHistory(VALIDATOR, TOKEN_A, SRC_PRYCD, 1).cycle, 1);
    }

    function test_historyRing_wrapsAtDepth() public {
        uint128 price = PRICE_100K;
        for (uint64 c = 1; c <= 10; ++c) {
            if (c > 1) {
                vm.warp(block.timestamp + 1 hours);
                price = price + 1e6;
            }
            _write(SRC_PRYCD, price, c);
        }
        assertEq(oracle.historyLength(VALIDATOR, TOKEN_A, SRC_PRYCD), 8);
        assertEq(oracle.getHistory(VALIDATOR, TOKEN_A, SRC_PRYCD, 0).cycle, 9);
    }

    function test_historyIndexOutOfBounds() public {
        vm.expectRevert(
            abi.encodeWithSelector(FabricaAttributeOracle.HistoryIndexOutOfBounds.selector, uint256(0), uint256(0))
        );
        oracle.getHistory(VALIDATOR, TOKEN_A, SRC_PRYCD, 0);
    }

    function test_heartbeat_setsFreshness() public {
        assertFalse(oracle.isHeartbeatFresh(VALIDATOR));
        vm.prank(publisher);
        vm.expectEmit(true, false, false, true);
        emit KeeperHeartbeat(VALIDATOR, 7, uint64(block.timestamp));
        oracle.heartbeat(VALIDATOR, 7);
        assertTrue(oracle.isHeartbeatFresh(VALIDATOR));
        assertEq(oracle.lastHeartbeatCycle(VALIDATOR), 7);
    }

    function test_heartbeat_expiresAfterMaxSilence() public {
        vm.prank(publisher);
        oracle.heartbeat(VALIDATOR, 1);
        assertTrue(oracle.isHeartbeatFresh(VALIDATOR));
        vm.warp(block.timestamp + 24 hours + 1);
        assertFalse(oracle.isHeartbeatFresh(VALIDATOR));
    }

    function test_heartbeat_rejectsBelowMinValidCycle() public {
        vm.prank(owner);
        oracle.setMinValidCycle(VALIDATOR, 10);
        vm.prank(publisher);
        vm.expectRevert(FabricaAttributeOracle.InvalidCycle.selector);
        oracle.heartbeat(VALIDATOR, 9);
    }

    function test_heartbeat_cycleNotMonotonic() public {
        vm.prank(publisher);
        oracle.heartbeat(VALIDATOR, 5);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.CycleNotMonotonic.selector, uint64(5), uint64(4)));
        oracle.heartbeat(VALIDATOR, 4);
    }

    function test_writePrice_piggybackHeartbeatCycleNotMonotonic() public {
        // Source 0 write at cycle 5 advances lastHeartbeatCycle via _touchHeartbeat.
        _write(SRC_PRYCD, PRICE_100K, 5);
        assertEq(oracle.lastHeartbeatCycle(VALIDATOR), 5);
        // First write on source 1 at lower cycle must not regress validator heartbeat cycle.
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.CycleNotMonotonic.selector, uint64(5), uint64(4)));
        oracle.writePrice(_priceParams(TOKEN_A, SRC_OPENAVM, PRICE_110K, 0, 4, _prov(publisher)));
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).priceUsdc6, PRICE_100K);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_OPENAVM).priceUsdc6, 0);
        assertEq(oracle.lastHeartbeatCycle(VALIDATOR), 5);
    }

    function test_writePrice_piggybacksHeartbeat() public {
        _write(SRC_PRYCD, PRICE_100K, 1);
        assertTrue(oracle.isHeartbeatFresh(VALIDATOR));
        assertEq(oracle.lastHeartbeatCycle(VALIDATOR), 1);
    }

    function test_setRecoveryStatus_separateRole() public {
        uint8 distressed = 4;
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.NotRecoveryWriter.selector, VALIDATOR, publisher));
        oracle.setRecoveryStatus(VALIDATOR, TOKEN_A, distressed);
        vm.prank(recoveryWriter);
        vm.expectEmit(true, true, true, true);
        emit RecoveryStatusSet(VALIDATOR, TOKEN_A, distressed, recoveryWriter);
        oracle.setRecoveryStatus(VALIDATOR, TOKEN_A, distressed);
        assertEq(oracle.recoveryStatusOf(VALIDATOR, TOKEN_A), distressed);
        assertFalse(oracle.isRecoveryNormal(VALIDATOR, TOKEN_A));
    }

    function test_setRecoveryStatus_requiresRegistered() public {
        vm.prank(recoveryWriter);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.NotRegistered.selector, VALIDATOR, TOKEN_B));
        oracle.setRecoveryStatus(VALIDATOR, TOKEN_B, 4);
    }

    function test_setRecoveryStatus_voidIrreversible() public {
        uint8 voidStatus = 1;
        uint8 normal = 7;
        vm.startPrank(recoveryWriter);
        oracle.setRecoveryStatus(VALIDATOR, TOKEN_A, voidStatus);
        vm.expectRevert(FabricaAttributeOracle.VoidIsIrreversible.selector);
        oracle.setRecoveryStatus(VALIDATOR, TOKEN_A, normal);
        vm.stopPrank();
    }

    function test_setRecoveryStatus_rejectsInvalidDigit() public {
        vm.prank(recoveryWriter);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.InvalidRecoveryStatus.selector, uint8(2)));
        oracle.setRecoveryStatus(VALIDATOR, TOKEN_A, 2);
    }

    function test_setRecoveryStatus_distressedThenNormal() public {
        vm.startPrank(recoveryWriter);
        oracle.setRecoveryStatus(VALIDATOR, TOKEN_A, 4);
        oracle.setRecoveryStatus(VALIDATOR, TOKEN_A, 7);
        vm.stopPrank();
        assertTrue(oracle.isRecoveryNormal(VALIDATOR, TOKEN_A));
    }

    function test_roleRevoke_blocksPublisher() public {
        vm.prank(owner);
        oracle.setPricePublisher(VALIDATOR, publisher, false);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.NotPricePublisher.selector, VALIDATOR, publisher));
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, _prov(publisher)));
    }

    function test_minValidCycle_blocksStaleWrites() public {
        _write(SRC_PRYCD, PRICE_100K, 5);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit CycleInvalidated(VALIDATOR, 10);
        oracle.setMinValidCycle(VALIDATOR, 10);
        assertFalse(oracle.isCycleValid(VALIDATOR, 5));
        assertTrue(oracle.isCycleValid(VALIDATOR, 10));
        // Raw getter still returns killed-cycle data — consumers must check isCycleValid.
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).cycle, 5);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(publisher);
        vm.expectRevert(FabricaAttributeOracle.InvalidCycle.selector);
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, PRICE_110K, 0, 9, _prov(publisher)));
        vm.prank(publisher);
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, PRICE_110K, 0, 10, _prov(publisher)));
    }

    function test_writePrice_invalidatedCurrentStartsNewBaseline() public {
        uint128 incidentPrice = 1_000_000e6;
        uint128 truePrice = PRICE_100K;
        _write(SRC_PRYCD, incidentPrice, 1);
        vm.prank(owner);
        oracle.setMinValidCycle(VALIDATOR, 2);
        uint128 maxFirstPrice = oracle.maxFirstPriceUsdc6();
        uint128 aboveFirst = maxFirstPrice + 1;
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaAttributeOracle.FirstPriceTooHigh.selector, aboveFirst, maxFirstPrice)
        );
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, aboveFirst, 0, 2, _prov(publisher)));
        vm.prank(publisher);
        oracle.writePrice(_priceParams(TOKEN_A, SRC_PRYCD, truePrice, 0, 2, _prov(publisher)));
        FabricaAttributeOracle.SourcePrice memory current = oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD);
        assertEq(current.priceUsdc6, truePrice);
        assertEq(current.cycle, 2);
        assertEq(oracle.historyLength(VALIDATOR, TOKEN_A, SRC_PRYCD), 1);
        assertEq(oracle.getHistory(VALIDATOR, TOKEN_A, SRC_PRYCD, 0).priceUsdc6, incidentPrice);
        assertEq(oracle.getHistory(VALIDATOR, TOKEN_A, SRC_PRYCD, 0).cycle, 1);
    }

    function test_minValidCycle_onlyIncreases() public {
        vm.startPrank(owner);
        oracle.setMinValidCycle(VALIDATOR, 5);
        vm.expectRevert(FabricaAttributeOracle.InvalidCycle.selector);
        oracle.setMinValidCycle(VALIDATOR, 5);
        vm.expectRevert(FabricaAttributeOracle.InvalidCycle.selector);
        oracle.setMinValidCycle(VALIDATOR, 4);
        vm.stopPrank();
    }

    function test_writeAttribute() public {
        bytes32 attrId = keccak256("landUse");
        bytes32 value = keccak256("vacant");
        FabricaAttributeOracle.Provenance memory prov = _prov(publisher);
        vm.prank(publisher);
        oracle.writeAttribute(VALIDATOR, TOKEN_A, attrId, value, 1, prov);
        assertEq(oracle.getAttribute(VALIDATOR, TOKEN_A, attrId).value, value);
        assertEq(oracle.getAttribute(VALIDATOR, TOKEN_A, attrId).cycle, 1);
        assertEq(oracle.getAttribute(VALIDATOR, TOKEN_A, attrId).provenance.signer, publisher);
    }

    function test_writeAttribute_cycleNotMonotonic() public {
        bytes32 attrId = keccak256("landUse");
        FabricaAttributeOracle.Provenance memory prov = _prov(publisher);
        vm.prank(publisher);
        oracle.writeAttribute(VALIDATOR, TOKEN_A, attrId, keccak256("vacant"), 5, prov);
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.CycleNotMonotonic.selector, uint64(5), uint64(4)));
        oracle.writeAttribute(VALIDATOR, TOKEN_A, attrId, keccak256("improved"), 4, prov);
        assertEq(oracle.getAttribute(VALIDATOR, TOKEN_A, attrId).value, keccak256("vacant"));
        assertEq(oracle.getAttribute(VALIDATOR, TOKEN_A, attrId).cycle, 5);
    }

    function test_writeAttribute_notPublisher() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.NotPricePublisher.selector, VALIDATOR, stranger));
        oracle.writeAttribute(VALIDATOR, TOKEN_A, keccak256("x"), bytes32(0), 1, _prov(stranger));
    }

    function test_writePriceRelayed() public {
        uint256 publisherPk = 0xA11CE;
        address publisherAddr = vm.addr(publisherPk);
        vm.prank(owner);
        oracle.setPricePublisher(VALIDATOR, publisherAddr, true);
        FabricaAttributeOracle.Provenance memory prov = _prov(publisherAddr);
        FabricaAttributeOracle.PriceWriteParams memory params =
            _priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 500, 1, prov);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPriceWrite(params, publisherPk, nonce, deadline);
        vm.prank(stranger);
        oracle.writePriceRelayed(params, nonce, deadline, sig);
        assertEq(oracle.getSourcePrice(VALIDATOR, TOKEN_A, SRC_PRYCD).priceUsdc6, PRICE_100K);
        assertEq(oracle.nonces(publisherAddr), 1);
    }

    function test_writePriceRelayed_rejectsBadNonce() public {
        uint256 publisherPk = 0xB0B;
        address publisherAddr = vm.addr(publisherPk);
        vm.prank(owner);
        oracle.setPricePublisher(VALIDATOR, publisherAddr, true);
        FabricaAttributeOracle.Provenance memory prov = _prov(publisherAddr);
        FabricaAttributeOracle.PriceWriteParams memory params = _priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, prov);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPriceWrite(params, publisherPk, 1, deadline);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.InvalidNonce.selector, uint256(0), uint256(1)));
        oracle.writePriceRelayed(params, 1, deadline, sig);
    }

    function test_writePriceRelayed_rejectsBadSignature() public {
        uint256 publisherPk = 0xA11CE;
        uint256 otherPk = 0xB0B;
        address publisherAddr = vm.addr(publisherPk);
        vm.prank(owner);
        oracle.setPricePublisher(VALIDATOR, publisherAddr, true);
        FabricaAttributeOracle.Provenance memory prov = _prov(publisherAddr);
        FabricaAttributeOracle.PriceWriteParams memory params = _priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, prov);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory badSig = _signPriceWrite(params, otherPk, 0, deadline);
        vm.expectRevert(FabricaAttributeOracle.InvalidSignature.selector);
        oracle.writePriceRelayed(params, 0, deadline, badSig);
    }

    function test_writePriceRelayed_rejectsReplay() public {
        uint256 publisherPk = 0xA11CE;
        address publisherAddr = vm.addr(publisherPk);
        vm.prank(owner);
        oracle.setPricePublisher(VALIDATOR, publisherAddr, true);
        FabricaAttributeOracle.Provenance memory prov = _prov(publisherAddr);
        FabricaAttributeOracle.PriceWriteParams memory params = _priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, prov);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPriceWrite(params, publisherPk, 0, deadline);
        oracle.writePriceRelayed(params, 0, deadline, sig);
        vm.expectRevert(abi.encodeWithSelector(FabricaAttributeOracle.InvalidNonce.selector, uint256(1), uint256(0)));
        oracle.writePriceRelayed(params, 0, deadline, sig);
    }

    function test_writePriceRelayed_rejectsExpired() public {
        uint256 publisherPk = 0xA11CE;
        address publisherAddr = vm.addr(publisherPk);
        vm.prank(owner);
        oracle.setPricePublisher(VALIDATOR, publisherAddr, true);
        FabricaAttributeOracle.Provenance memory prov = _prov(publisherAddr);
        FabricaAttributeOracle.PriceWriteParams memory params = _priceParams(TOKEN_A, SRC_PRYCD, PRICE_100K, 0, 1, prov);
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _signPriceWrite(params, publisherPk, 0, deadline);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaAttributeOracle.ExpiredSignature.selector, deadline, block.timestamp)
        );
        oracle.writePriceRelayed(params, 0, deadline, sig);
    }

    function test_anchorRoot() public {
        bytes32 root = keccak256("book");
        vm.prank(owner);
        oracle.anchorRoot(VALIDATOR, 3, root);
        assertEq(oracle.cycleRoot(VALIDATOR, 3), root);
    }

    function _defaultKnobs() internal pure returns (FabricaAttributeOracle.KnobConfig memory) {
        return FabricaAttributeOracle.KnobConfig({
            maxUpBps: 1500,
            maxDownBps: 5000,
            maxFirstPriceUsdc6: 50_000_000e6,
            maxSilence: 24 hours,
            minWriteInterval: 1 hours,
            registrySeasonDelay: 1 days,
            valueCeilingUsdc6: 50_000_000e6,
            historyDepth: 8
        });
    }

    function _prov(address signer) internal view returns (FabricaAttributeOracle.Provenance memory) {
        return FabricaAttributeOracle.Provenance({
            rawPayloadHash: keccak256("payload"),
            inputsHash: keccak256("inputs"),
            timestamp: uint64(block.timestamp),
            signer: signer
        });
    }

    function _priceParams(
        uint256 tokenId,
        uint8 sourceId,
        uint128 price,
        uint24 confidence,
        uint64 cycle,
        FabricaAttributeOracle.Provenance memory prov
    ) internal view returns (FabricaAttributeOracle.PriceWriteParams memory) {
        return FabricaAttributeOracle.PriceWriteParams({
            validatorId: VALIDATOR,
            tokenId: tokenId,
            sourceId: sourceId,
            priceUsdc6: price,
            confidenceScore: confidence,
            valuedAt: uint64(block.timestamp),
            cycle: cycle,
            provenance: prov
        });
    }

    function _write(uint8 sourceId, uint128 price, uint64 cycle) internal {
        vm.prank(publisher);
        oracle.writePrice(_priceParams(TOKEN_A, sourceId, price, 0, cycle, _prov(publisher)));
    }

    function _signPriceWrite(
        FabricaAttributeOracle.PriceWriteParams memory params,
        uint256 pk,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = oracle.hashPriceWrite(params, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
