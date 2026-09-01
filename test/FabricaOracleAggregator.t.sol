// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaOracleAggregator} from "../src/FabricaOracleAggregator.sol";
import {IFabricaAttributeOracle} from "../src/interfaces/IFabricaAttributeOracle.sol";

/// @notice Minimal mock of ENG-3518 fact store for aggregator unit tests.
contract MockFactStore is IFabricaAttributeOracle {
    mapping(uint8 => bool) public sourceEnabled;
    mapping(uint256 => mapping(uint256 => mapping(uint8 => SourcePrice))) internal _prices;
    mapping(uint256 => mapping(uint256 => mapping(uint8 => HistoryEntry[]))) internal _history;
    mapping(uint256 => mapping(uint256 => uint8)) internal _recovery;
    mapping(uint256 => mapping(uint256 => bool)) internal _seasoned;
    mapping(uint256 => bool) internal _heartbeat;
    mapping(uint256 => uint64) public minValidCycle;
    mapping(uint256 => mapping(uint256 => mapping(bytes32 => AttributeFact))) internal _attrs;

    uint8 public constant RECOVERY_NORMAL = 7;

    function setSourceEnabled(uint8 sid, bool on) external {
        sourceEnabled[sid] = on;
    }

    function setHeartbeat(uint256 vid, bool fresh) external {
        _heartbeat[vid] = fresh;
    }

    function setSeasoned(uint256 vid, uint256 tokenId, bool ok) external {
        _seasoned[vid][tokenId] = ok;
    }

    function setRecoveryNormal(uint256 vid, uint256 tokenId, bool ok) external {
        _recovery[vid][tokenId] = ok ? RECOVERY_NORMAL : 4;
    }

    function setMinValidCycle(uint256 vid, uint64 c) external {
        minValidCycle[vid] = c;
    }

    function setPrice(uint256 vid, uint256 tokenId, uint8 sid, uint128 priceUsdc6, uint64 valuedAt, uint64 cycle)
        external
    {
        SourcePrice storage sp = _prices[vid][tokenId][sid];
        // Push previous into history (newest-first via array push then we reverse on read).
        if (sp.priceUsdc6 != 0) {
            _history[vid][tokenId][sid].push(
                HistoryEntry({
                    priceUsdc6: sp.priceUsdc6, valuedAt: sp.valuedAt, lastWrittenAt: sp.lastWrittenAt, cycle: sp.cycle
                })
            );
        }
        sp.priceUsdc6 = priceUsdc6;
        sp.valuedAt = valuedAt;
        sp.lastWrittenAt = uint64(block.timestamp);
        sp.cycle = cycle;
    }

    function setLastWrittenAt(uint256 vid, uint256 tokenId, uint8 sid, uint64 ts) external {
        _prices[vid][tokenId][sid].lastWrittenAt = ts;
    }

    function clearHistory(uint256 vid, uint256 tokenId, uint8 sid) external {
        delete _history[vid][tokenId][sid];
    }

    function pushHistory(
        uint256 vid,
        uint256 tokenId,
        uint8 sid,
        uint128 priceUsdc6,
        uint64 valuedAt,
        uint64 lastWrittenAt,
        uint64 cycle
    ) external {
        _history[vid][tokenId][sid].push(
            HistoryEntry({priceUsdc6: priceUsdc6, valuedAt: valuedAt, lastWrittenAt: lastWrittenAt, cycle: cycle})
        );
    }

    function setAttribute(uint256 vid, uint256 tokenId, bytes32 id, bytes32 value, uint64 cycle) external {
        _attrs[vid][tokenId][id] =
            AttributeFact({value: value, cycle: cycle, provenance: Provenance(bytes32(0), bytes32(0), 0, address(0))});
    }

    function getSourcePrice(uint256 validatorId, uint256 tokenId, uint8 sourceId)
        external
        view
        returns (SourcePrice memory)
    {
        return _prices[validatorId][tokenId][sourceId];
    }

    function isRecoveryNormal(uint256 validatorId, uint256 tokenId) external view returns (bool) {
        return _recovery[validatorId][tokenId] == RECOVERY_NORMAL;
    }

    function getAttribute(uint256 validatorId, uint256 tokenId, bytes32 attributeId)
        external
        view
        returns (AttributeFact memory)
    {
        return _attrs[validatorId][tokenId][attributeId];
    }

    function isRegistrySeasoned(uint256 validatorId, uint256 tokenId) external view returns (bool) {
        return _seasoned[validatorId][tokenId];
    }

    function isHeartbeatFresh(uint256 validatorId) external view returns (bool) {
        return _heartbeat[validatorId];
    }

    function isCycleValid(uint256 validatorId, uint64 cycle) external view returns (bool) {
        return cycle >= minValidCycle[validatorId];
    }

    function historyLength(uint256 validatorId, uint256 tokenId, uint8 sourceId) external view returns (uint256) {
        return _history[validatorId][tokenId][sourceId].length;
    }

    // Newest-first: last push is newest previous entry → index 0 = last element.
    function getHistory(uint256 validatorId, uint256 tokenId, uint8 sourceId, uint256 index)
        external
        view
        returns (HistoryEntry memory)
    {
        HistoryEntry[] storage h = _history[validatorId][tokenId][sourceId];
        return h[h.length - 1 - index];
    }
}

contract FabricaOracleAggregatorTest is Test {
    MockFactStore internal store;
    FabricaOracleAggregator internal agg;

    address internal owner;
    address internal usdc;
    uint256 internal constant VID = 1;
    uint256 internal constant TOKEN = 42;

    uint256[] internal tokenIds;
    uint256[] internal qtys;

    function setUp() public {
        vm.warp(2_000_000);
        owner = makeAddr("owner");
        store = new MockFactStore();
        // usdc must be a contract address for renounce code.length checks.
        usdc = address(store);
        store.setSourceEnabled(0, true);
        store.setSourceEnabled(1, true);
        store.setSourceEnabled(2, true);
        uint8[] memory sources = new uint8[](3);
        sources[0] = 0;
        sources[1] = 1;
        sources[2] = 2;
        agg = new FabricaOracleAggregator(
            owner,
            address(store),
            usdc,
            VID,
            sources,
            24 hours, // seasoning
            5000, // 50% jump breaker
            20_000, // 2.0× dispersion
            2
        );
        tokenIds = new uint256[](1);
        tokenIds[0] = TOKEN;
        qtys = new uint256[](1);
        qtys[0] = 1;
        _baselineHealthy();
    }

    function _baselineHealthy() internal {
        store.setHeartbeat(VID, true);
        store.setSeasoned(VID, TOKEN, true);
        store.setRecoveryNormal(VID, TOKEN, true);
        uint64 nowTs = uint64(block.timestamp);
        // Three feeds around 100k with old history for temporal floor.
        store.setPrice(VID, TOKEN, 0, 100_000e6, nowTs, 1);
        store.setPrice(VID, TOKEN, 1, 100_000e6, nowTs, 1);
        store.setPrice(VID, TOKEN, 2, 100_000e6, nowTs, 1);
        // Prior prices 24h+ ago so temporal doesn't floor below current.
        uint64 past = nowTs - 25 hours;
        store.pushHistory(VID, TOKEN, 0, 100_000e6, past, past, 1);
        store.pushHistory(VID, TOKEN, 1, 100_000e6, past, past, 1);
        store.pushHistory(VID, TOKEN, 2, 100_000e6, past, past, 1);
    }

    function _price() internal view returns (uint256) {
        return agg.price(address(0), usdc, tokenIds, qtys, "");
    }

    function test_price_minOfThreeFeeds() public {
        uint64 nowTs = uint64(block.timestamp);
        store.setPrice(VID, TOKEN, 0, 100_000e6, nowTs, 2);
        store.setPrice(VID, TOKEN, 1, 90_000e6, nowTs, 2);
        store.setPrice(VID, TOKEN, 2, 110_000e6, nowTs, 2);
        // past history so temporal doesn't change MIN
        uint64 past = nowTs - 25 hours;
        store.pushHistory(VID, TOKEN, 0, 100_000e6, past, past, 1);
        store.pushHistory(VID, TOKEN, 1, 90_000e6, past, past, 1);
        store.pushHistory(VID, TOKEN, 2, 110_000e6, past, past, 1);
        assertEq(_price(), 90_000e6);
    }

    function test_price_rejectsBadCurrency() public {
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_CURRENCY()));
        agg.price(address(0), makeAddr("dai"), tokenIds, qtys, "");
    }

    function test_price_rejectsStaleHeartbeat() public {
        store.setHeartbeat(VID, false);
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_HEARTBEAT()));
        _price();
    }

    function test_price_rejectsUnseasoned() public {
        store.setSeasoned(VID, TOKEN, false);
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_REGISTRY()));
        _price();
    }

    function test_price_rejectsBadRecovery() public {
        store.setRecoveryNormal(VID, TOKEN, false);
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_RECOVERY()));
        _price();
    }

    function test_price_minSourcesFailClosed() public {
        // Only one live source.
        store.setPrice(VID, TOKEN, 1, 0, 0, 0);
        store.setPrice(VID, TOKEN, 2, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_MIN_SOURCES()));
        _price();
    }

    function test_price_breakerDropsOutlierThenMin() public {
        uint64 nowTs = uint64(block.timestamp);
        // Feed 2 jumped 100k → 200k (100% > 50% breaker) vs history.
        store.setPrice(VID, TOKEN, 0, 100_000e6, nowTs, 3);
        store.setPrice(VID, TOKEN, 1, 100_000e6, nowTs, 3);
        store.setPrice(VID, TOKEN, 2, 200_000e6, nowTs, 3);
        uint64 past = nowTs - 25 hours;
        // Clear history by using pushHistory only for prior — setPrice already pushed.
        // Ensure history[0] for source 2 is 100k: setPrice pushes previous when updating.
        // Rebuild cleanly:
        // We need prior of 100k for feed 2. setPrice already pushed old 100k when set to 200k.
        store.pushHistory(VID, TOKEN, 0, 100_000e6, past, past, 1);
        store.pushHistory(VID, TOKEN, 1, 100_000e6, past, past, 1);
        // Feed 2 history newest should be previous current from setPrice chain.
        // After setPrice to 200k, history includes 100k entry from setUp overwrite path.
        assertEq(_price(), 100_000e6); // feed 2 dropped; MIN of remaining = 100k
    }

    function test_price_breakerLeavesLessThanTwoFreezes() public {
        uint64 nowTs = uint64(block.timestamp);
        // Only two feeds live; both jump hard.
        store.setSourceEnabled(2, false);
        store.setPrice(VID, TOKEN, 0, 200_000e6, nowTs, 5);
        store.setPrice(VID, TOKEN, 1, 200_000e6, nowTs, 5);
        // History prior 100k for both so jump = 100%.
        // setPrice pushed previous.
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_MIN_SOURCES()));
        _price();
    }

    function test_price_temporalFloorMinThenTemporal() public {
        // Current MIN = 140k; past MIN at N ago = 100k → usable 100k.
        // Use small jumps so rate-of-change breaker does not drop feeds (maxJumpBps=50%).
        uint64 nowTs = uint64(block.timestamp);
        uint64 past = nowTs - 25 hours;
        // Seed genuinely old wall-clock history; current writes stay at nowTs.
        for (uint8 s; s < 3; ++s) {
            store.setPrice(VID, TOKEN, s, 100_000e6, past, 9);
            store.setLastWrittenAt(VID, TOKEN, s, past);
        }
        store.setPrice(VID, TOKEN, 0, 140_000e6, nowTs, 10); // +40%
        store.setPrice(VID, TOKEN, 1, 145_000e6, nowTs, 10);
        store.setPrice(VID, TOKEN, 2, 149_000e6, nowTs, 10);
        // History[0] is 100k@lastWrittenAt=past. Temporal pastMin=100k; currentMin=140k.
        assertEq(_price(), 100_000e6);
    }

    function test_price_dispersionFails() public {
        uint64 nowTs = uint64(block.timestamp);
        store.setPrice(VID, TOKEN, 0, 100_000e6, nowTs, 2);
        store.setPrice(VID, TOKEN, 1, 100_000e6, nowTs, 2);
        store.setPrice(VID, TOKEN, 2, 250_000e6, nowTs, 2); // 2.5× > 2.0×
        uint64 past = nowTs - 25 hours;
        store.pushHistory(VID, TOKEN, 0, 100_000e6, past, past, 1);
        store.pushHistory(VID, TOKEN, 1, 100_000e6, past, past, 1);
        store.pushHistory(VID, TOKEN, 2, 250_000e6, past, past, 1);
        // Jump from history for feed 2: if previous was also 250k, no breaker.
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_DISPERSION()));
        _price();
    }

    function test_price_multiTokenAverage() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory q = new uint256[](2);
        ids[0] = TOKEN;
        ids[1] = 99;
        q[0] = 1;
        q[1] = 1;
        store.setSeasoned(VID, 99, true);
        store.setRecoveryNormal(VID, 99, true);
        uint64 nowTs = uint64(block.timestamp);
        uint64 past = nowTs - 25 hours;
        for (uint8 s; s < 3; ++s) {
            store.setPrice(VID, 99, s, 50_000e6, nowTs, 1);
            store.pushHistory(VID, 99, s, 50_000e6, past, past, 1);
        }
        // TOKEN still 100k MIN, 99 is 50k → avg 75k
        assertEq(agg.price(address(0), usdc, ids, q, ""), 75_000e6);
    }

    function test_eligibilityReport() public {
        store.setHeartbeat(VID, false);
        (bool ok, bytes32 failed) = agg.eligibilityReport(usdc, TOKEN);
        assertFalse(ok);
        assertEq(failed, agg.CHECK_HEARTBEAT());
    }

    function test_renounce_rejectsMinLiveExceedsSources() public {
        // Configure only 2 sources while minLiveSources is 2 — ok.
        // Raise minLiveSources above source count without changing sources.
        uint8[] memory two = new uint8[](2);
        two[0] = 0;
        two[1] = 1;
        vm.startPrank(owner);
        agg.setSourceIds(two);
        agg.setKnobs(24 hours, 5000, 20_000, 2);
        // Now set minLiveSources=3 with only 2 sources via setKnobs — setKnobs allows it
        // (cross-check is at renounce). Wait: setKnobs doesn't know about source count.
        // Set minLive to 3:
        agg.setKnobs(24 hours, 5000, 20_000, 3);
        vm.expectRevert(FabricaOracleAggregator.InvalidConfig.selector);
        agg.renounceAggregator();
        vm.stopPrank();
    }

    function test_renounceFreezesSetters() public {
        vm.prank(owner);
        agg.renounceAggregator();
        assertTrue(agg.renounced());
        assertEq(agg.owner(), address(0));
        // onlyOwner fails first (owner is zero); renounced flag is set for documentation/guards.
        vm.expectRevert();
        vm.prank(owner);
        agg.setKnobs(1 hours, 1000, 15_000, 2);
    }

    function test_renounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(FabricaOracleAggregator.NotRenounceable.selector);
        agg.renounceOwnership();
    }

    function test_designReviewDefaults() public view {
        (uint64 sw, uint16 jump, uint16 disp, uint8 minSrc, string memory order, string memory evo) =
            agg.designReviewDefaults();
        assertEq(sw, 24 hours);
        assertEq(jump, 5000);
        assertEq(disp, 20_000);
        assertEq(minSrc, 2);
        assertEq(keccak256(bytes(order)), keccak256("MIN-then-temporal"));
        assertEq(keccak256(bytes(evo)), keccak256("immutable-post-renounce; new-checks=new-aggregator-deploy"));
    }

    function test_breaker_invalidHistoryCycleStartsNewBaseline() public {
        // Two feeds only; history for both is cycle 1; bump minValidCycle so prior is invalid.
        // Current prices at cycle 10 are valid and become the post-invalidation breaker baseline.
        store.setSourceEnabled(2, false);
        uint64 nowTs = uint64(block.timestamp);
        store.setPrice(VID, TOKEN, 0, 100_000e6, nowTs - 1, 1);
        store.setPrice(VID, TOKEN, 1, 100_000e6, nowTs - 1, 1);
        store.setPrice(VID, TOKEN, 0, 200_000e6, nowTs, 10);
        store.setPrice(VID, TOKEN, 1, 200_000e6, nowTs, 10);
        // History cycle 1 is invalid; current cycle 10 is valid.
        store.setMinValidCycle(VID, 5);
        assertEq(_price(), 200_000e6);

        store.setPrice(VID, TOKEN, 0, 250_000e6, nowTs, 11);
        store.setPrice(VID, TOKEN, 1, 250_000e6, nowTs, 11);
        assertEq(_price(), 250_000e6);

        store.setPrice(VID, TOKEN, 0, 400_000e6, nowTs, 12);
        store.setPrice(VID, TOKEN, 1, 400_000e6, nowTs, 12);
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_MIN_SOURCES()));
        _price();
    }

    function test_setSourceIds_rejectsDuplicates() public {
        uint8[] memory bad = new uint8[](2);
        bad[0] = 0;
        bad[1] = 0;
        vm.prank(owner);
        vm.expectRevert(FabricaOracleAggregator.InvalidConfig.selector);
        agg.setSourceIds(bad);
    }

    function test_price_dropsInvalidCycleFeeds() public {
        store.setMinValidCycle(VID, 10);
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_MIN_SOURCES()));
        _price();
    }

    function test_price_temporalIgnoresBackdatedValuedAt() public {
        // Keep write timestamps current; only valuedAt is backdated on current.
        // Prior history must use genuine old lastWrittenAt so temporal floor applies.
        uint64 nowTs = uint64(block.timestamp);
        uint64 past = nowTs - 25 hours;
        for (uint8 s; s < 3; ++s) {
            store.setPrice(VID, TOKEN, s, 100_000e6, past, 1);
            store.setLastWrittenAt(VID, TOKEN, s, past);
        }
        for (uint8 s; s < 3; ++s) {
            // Backdated valuedAt, current wall-clock write time (setPrice sets lastWrittenAt=now).
            store.setPrice(VID, TOKEN, s, 140_000e6, past, 2);
        }
        assertEq(_price(), 100_000e6);
    }

    function test_priceAsOf_requiresNonzeroLastWrittenAt() public {
        // History with old valuedAt but lastWrittenAt==0 must NOT floor the temporal path.
        // (+40% jump stays under maxJumpBps=50% so breaker does not drop feeds.)
        uint64 nowTs = uint64(block.timestamp);
        uint64 past = nowTs - 25 hours;
        for (uint8 s; s < 3; ++s) {
            store.clearHistory(VID, TOKEN, s);
            store.setPrice(VID, TOKEN, s, 140_000e6, nowTs, 2);
            store.clearHistory(VID, TOKEN, s);
            store.pushHistory(VID, TOKEN, s, 100_000e6, past, 0, 1);
        }
        // If valuedAt fallback were used, pastMin=100k and price would floor. Strict path: 140k.
        assertEq(_price(), 140_000e6);
        // Same prices with trusted lastWrittenAt on history → temporal floors to 100k.
        for (uint8 s; s < 3; ++s) {
            store.clearHistory(VID, TOKEN, s);
            store.pushHistory(VID, TOKEN, s, 100_000e6, past, past, 1);
        }
        assertEq(_price(), 100_000e6);
    }

    function test_constructor_rejectsEoaDependencies() public {
        address eoa = makeAddr("eoa-dep");
        uint8[] memory sources = new uint8[](2);
        sources[0] = 0;
        sources[1] = 1;
        vm.expectRevert(FabricaOracleAggregator.InvalidConfig.selector);
        new FabricaOracleAggregator(owner, eoa, address(store), VID, sources, 24 hours, 5000, 20_000, 2);
        vm.expectRevert(FabricaOracleAggregator.InvalidConfig.selector);
        new FabricaOracleAggregator(owner, address(store), eoa, VID, sources, 24 hours, 5000, 20_000, 2);
    }

    function test_setters_rejectEoaDependencies() public {
        address eoa = makeAddr("eoa-dep");
        vm.startPrank(owner);
        vm.expectRevert(FabricaOracleAggregator.InvalidConfig.selector);
        agg.setFactStore(eoa);
        vm.expectRevert(FabricaOracleAggregator.InvalidConfig.selector);
        agg.setUsdc(eoa);
        vm.stopPrank();
    }

    function test_renounce_acceptsDistinctContractUsdc() public {
        MockFactStore usdcToken = new MockFactStore();
        vm.prank(owner);
        agg.setUsdc(address(usdcToken));
        vm.prank(owner);
        agg.renounceAggregator();
        assertTrue(agg.renounced());
        assertEq(agg.usdc(), address(usdcToken));
    }

    function test_landUseCheck() public {
        vm.prank(owner);
        agg.setLandUsePolicy(true, keccak256("vacant"));
        // Missing attribute → fail
        vm.expectRevert(abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, agg.CHECK_LAND_USE()));
        _price();
        store.setAttribute(VID, TOKEN, keccak256("landUse"), keccak256("vacant"), 1);
        assertEq(_price(), 100_000e6);
    }
}
