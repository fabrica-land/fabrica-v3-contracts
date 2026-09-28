// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {FabricaFactStore} from "../src/FabricaFactStore.sol";
import {FabricaRegionRuleAggregator} from "../src/FabricaRegionRuleAggregator.sol";

/// @notice Stand-in for USDC. The aggregator only requires the currency address to hold code.
contract RegionCurrencyStub {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

/// @notice ENG-4397 — region and vacant-land gate on the ENG-4414 successor shape.
/// @dev Runs against the real `FabricaFactStore`. `FabricaImmutableAggregator` is not under test
///      here and is not modified: this contract is the further aggregator.
contract FabricaRegionRuleAggregatorTest is Test {
    uint8 internal constant MIN_LIVE_SOURCES = 2;
    uint64 internal constant MAX_SILENCE = 3 days;
    uint64 internal constant CYCLE_CLOSE_INTERVAL = 1 days;
    uint64 internal constant SEASONING_WINDOW = 24 hours;
    uint16 internal constant MAX_JUMP_BPS = 5000;
    uint16 internal constant MAX_DISPERSION_BPS = 20_000;
    uint128 internal constant MAX_FIRST_PRICE_USDC6 = 50_000_000e6;
    uint128 internal constant VALUE_CEILING_USDC6 = 50_000_000e6;
    uint8 internal constant HISTORY_DEPTH = 48;

    uint256 internal constant TOKEN_ID = 3561233430243998108;
    uint64 internal constant CYCLE = 1;
    uint24 internal constant CONFIDENCE = 9000;
    uint128 internal constant ELIGIBILITY_PASS = 3;

    uint128 internal constant SEASONED_PRYCD = 84_000e6;
    uint128 internal constant SEASONED_OPENAVM = 82_000e6;
    uint128 internal constant SEASONED_REGRID = 80_000e6;
    uint128 internal constant LIVE_PRYCD = 92_000e6;
    uint128 internal constant LIVE_OPENAVM = 90_000e6;
    uint128 internal constant LIVE_REGRID = 88_000e6;
    uint128 internal constant EXPECTED_USABLE = SEASONED_REGRID;

    // viem recomputation of the API writer's pack for the spec fixture (United States / Massachusetts).
    uint128 internal constant US_DIGEST = 2362504821423185609;
    uint128 internal constant MA_DIGEST = 1902571803460595491;
    uint128 internal constant US_MA_VACANT = 0x41929b3c6a273d92699d2be663c5bc8f;
    uint128 internal constant US_MA_IMPROVED = 0x41929b3c6a273d92699d2be663c5bc8d;
    uint128 internal constant US_MA_UNKNOWN = 0x41929b3c6a273d92699d2be663c5bc8c;
    uint128 internal constant US_MA_RESERVED = 0x41929b3c6a273d92699d2be663c5bc8e;
    uint128 internal constant US_CA_VACANT = 0x41929b3c6a273d93ca90c98af6e58cdb;

    FabricaFactStore internal store;
    FabricaRegionRuleAggregator internal aggregator;
    address internal usdc;

    address internal prycd = makeAddr("eng4397-writer-prycd");
    address internal openAvm = makeAddr("eng4397-writer-openavm");
    address internal regrid = makeAddr("eng4397-writer-regrid");
    address internal eligibilityWriter = makeAddr("eng4397-eligibility-writer");
    address internal jurisdictionWriter = makeAddr("eng4397-jurisdiction-writer");

    function setUp() public {
        vm.warp(1_780_000_000);
        usdc = address(new RegionCurrencyStub());
        store = new FabricaFactStore(HISTORY_DEPTH);
        aggregator = new FabricaRegionRuleAggregator(_config());
        _seedSeasonedThenLive();
        _writeEligibility(TOKEN_ID, ELIGIBILITY_PASS, CYCLE);
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, US_MA_VACANT, CYCLE, true);
    }

    function test_checkIds_regionIdsArePinnedAndDistinct() public view {
        assertEq(
            aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(),
            keccak256("eligibility_region_unattested"),
            "eligibility_region_unattested"
        );
        assertEq(aggregator.CHECK_ELIGIBILITY_REGION(), keccak256("eligibility_region"), "eligibility_region");
        assertEq(
            aggregator.CHECK_ELIGIBILITY_VACANT_LAND(), keccak256("eligibility_vacant_land"), "eligibility_vacant_land"
        );
        assertEq(
            aggregator.KIND_JURISDICTION(),
            bytes32(0xa3dc8e958fbec885b73a7523c370c78efd961785104448d422a3bbe5e5832a78),
            "KIND_JURISDICTION"
        );
        assertNotEq(aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(), aggregator.CHECK_ELIGIBILITY_REGION());
        assertNotEq(aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(), aggregator.CHECK_ELIGIBILITY_VACANT_LAND());
        assertNotEq(aggregator.CHECK_ELIGIBILITY_REGION(), aggregator.CHECK_ELIGIBILITY_VACANT_LAND());
        assertNotEq(aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(), aggregator.CHECK_ELIGIBILITY_UNATTESTED());
        assertNotEq(aggregator.CHECK_ELIGIBILITY_REGION(), aggregator.CHECK_ELIGIBILITY());
        assertNotEq(aggregator.CHECK_ELIGIBILITY_VACANT_LAND(), aggregator.CHECK_ELIGIBILITY());
    }

    function test_checkIds_eng4327IdsUnchanged() public view {
        assertEq(
            aggregator.CHECK_ELIGIBILITY_UNATTESTED(), keccak256("eligibility_unattested"), "eligibility_unattested"
        );
        assertEq(aggregator.CHECK_ELIGIBILITY(), keccak256("eligibility"), "eligibility");
        assertNotEq(aggregator.CHECK_ELIGIBILITY_UNATTESTED(), keccak256("eligibility_unavailable"));
    }

    function test_constructor_hashesUnitedStatesAndMassachusetts() public {
        assertEq(aggregator.allowedCountryDigest(), US_DIGEST, "country digest");
        assertEq(aggregator.allowedRegionCount(), 1, "one allowed region");
        assertEq(aggregator.allowedRegionDigestAt(0), MA_DIGEST, "region digest");
        assertEq(aggregator.jurisdictionWriter(), jurisdictionWriter, "jurisdiction writer");
        FabricaRegionRuleAggregator.Config memory sameSigner = _config();
        sameSigner.jurisdictionWriter = eligibilityWriter;
        FabricaRegionRuleAggregator shared = new FabricaRegionRuleAggregator(sameSigner);
        assertEq(shared.jurisdictionWriter(), eligibilityWriter, "jurisdiction writer may equal eligibility writer");
        vm.recordLogs();
        new FabricaRegionRuleAggregator(_config());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 regionTopic = keccak256("RegionRuleConfigured(address,string,uint128,string[],uint128[])");
        bytes32 deployedTopic = keccak256(
            "AggregatorDeployed(address,address,address,address[],uint128,uint8,uint64,uint64,uint64,uint16,uint16,uint128,uint128)"
        );
        bool foundRegion;
        bool foundDeployed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == regionTopic) {
                (string memory country, uint128 countryDigest, string memory region, uint128 regionDigest) =
                    _decodeRegionRule(logs[i].data);
                assertEq(address(uint160(uint256(logs[i].topics[1]))), jurisdictionWriter, "event jurisdictionWriter");
                assertEq(country, "United States", "event country string");
                assertEq(countryDigest, US_DIGEST, "event country digest");
                assertEq(region, "Massachusetts", "event region string");
                assertEq(regionDigest, MA_DIGEST, "event region digest");
                foundRegion = true;
            }
            if (logs[i].topics[0] == deployedTopic) {
                _assertDeployed(logs[i]);
                foundDeployed = true;
            }
        }
        assertTrue(foundRegion, "RegionRuleConfigured topic");
        assertTrue(foundDeployed, "AggregatorDeployed topic");
    }

    function test_vector_unitedStatesMassachusettsVacantPack() public view {
        uint128 pack = 0x41929b3c6a273d92699d2be663c5bc8f;
        assertEq(pack >> 65, US_DIGEST, "pack country digest");
        assertEq((pack >> 2) & ((uint128(1) << 63) - 1), MA_DIGEST, "pack region digest");
        assertEq(pack & 3, 3, "pack vacancy 11");
        assertEq(US_DIGEST, 2362504821423185609, "literal country digest");
        assertEq(MA_DIGEST, 1902571803460595491, "literal region digest");
        assertEq(aggregator.allowedCountryDigest(), 2362504821423185609, "constructor country digest");
        assertEq(aggregator.allowedRegionDigestAt(0), 1902571803460595491, "constructor region digest");
        assertEq(US_MA_VACANT, pack, "vacant pack constant");
    }

    function test_constructor_rejectsEmptyCountryEmptyRegionAndDuplicates() public {
        FabricaRegionRuleAggregator.Config memory config = _config();
        config.allowedCountry = "";
        vm.expectRevert(FabricaRegionRuleAggregator.EmptyJurisdictionName.selector);
        new FabricaRegionRuleAggregator(config);
        config = _config();
        config.allowedRegions = _regions("", "");
        vm.expectRevert(FabricaRegionRuleAggregator.EmptyJurisdictionName.selector);
        new FabricaRegionRuleAggregator(config);
        config = _config();
        config.allowedRegions = _regions("Massachusetts", "Massachusetts");
        vm.expectRevert(abi.encodeWithSelector(FabricaRegionRuleAggregator.DuplicateRegion.selector, MA_DIGEST));
        new FabricaRegionRuleAggregator(config);
        config = _config();
        config.allowedRegions = new string[](17);
        for (uint256 i; i < 17; ++i) {
            config.allowedRegions[i] = string.concat("Region", vm.toString(i));
        }
        vm.expectRevert(abi.encodeWithSelector(FabricaRegionRuleAggregator.TooManyRegions.selector, 17, 16));
        new FabricaRegionRuleAggregator(config);
    }

    function test_constructor_rejectsJurisdictionWriterZeroOrPriceWriter() public {
        FabricaRegionRuleAggregator.Config memory config = _config();
        config.jurisdictionWriter = address(0);
        vm.expectRevert(FabricaRegionRuleAggregator.ZeroAddress.selector);
        new FabricaRegionRuleAggregator(config);
        config = _config();
        config.jurisdictionWriter = prycd;
        vm.expectRevert(
            abi.encodeWithSelector(FabricaRegionRuleAggregator.JurisdictionWriterIsPriceWriter.selector, prycd)
        );
        new FabricaRegionRuleAggregator(config);
    }

    function test_region_unitedStatesMassachusettsVacantPrices() public view {
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertTrue(ok, "US/MA vacant prices");
        assertEq(failed, bytes32(0), "no failed check");
        assertEq(_price(aggregator, TOKEN_ID), EXPECTED_USABLE, "seasoned minimum");
    }

    function test_region_unitedStatesCaliforniaVacantPricesWhenAllowed() public {
        FabricaRegionRuleAggregator california =
            new FabricaRegionRuleAggregator(_configWith("United States", _regions("California"), jurisdictionWriter));
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, US_CA_VACANT, CYCLE, false);
        (bool ok, bytes32 failed) = california.eligibilityReport(usdc, TOKEN_ID);
        assertTrue(ok, "US/CA vacant prices when California is allowed");
        assertEq(failed, bytes32(0));
        assertEq(_price(california, TOKEN_ID), EXPECTED_USABLE, "priced");
    }

    function test_region_emptyStateListAllowsAnyRegionInCountry() public {
        FabricaRegionRuleAggregator countryWide =
            new FabricaRegionRuleAggregator(_configWith("United States", new string[](0), jurisdictionWriter));
        assertEq(countryWide.allowedRegionCount(), 0, "empty state list");
        (bool maOk,) = countryWide.eligibilityReport(usdc, TOKEN_ID);
        assertTrue(maOk, "Massachusetts passes a country-only rule");
        assertEq(_price(countryWide, TOKEN_ID), EXPECTED_USABLE, "Massachusetts priced");
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, US_CA_VACANT, CYCLE, false);
        (bool caOk, bytes32 failed) = countryWide.eligibilityReport(usdc, TOKEN_ID);
        assertTrue(caOk, "California passes a country-only rule");
        assertEq(failed, bytes32(0));
        assertEq(_price(countryWide, TOKEN_ID), EXPECTED_USABLE, "California priced");
    }

    function test_region_missingFactIsUnattested() public {
        uint256 token = TOKEN_ID + 1;
        _seedLivePrices(token);
        _writeEligibility(token, ELIGIBILITY_PASS, CYCLE);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, token);
        assertFalse(ok, "missing jurisdiction fact refuses");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(), "missing fact is region-unattested");
        assertNotEq(failed, aggregator.CHECK_ELIGIBILITY_UNATTESTED(), "ENG-4327 already passed");
        _expect(aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED());
        _priceCall(aggregator, token);
    }

    function test_region_lockIsUnattested() public {
        vm.prank(jurisdictionWriter);
        store.setLock(jurisdictionWriter, TOKEN_ID, true);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "a locked jurisdiction fact refuses");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(), "lock is region-unattested");
        _expect(aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED());
        _priceCall(aggregator, TOKEN_ID);
    }

    function test_region_staleCloseIsUnattested() public {
        vm.warp(block.timestamp + MAX_SILENCE + 1);
        vm.prank(prycd);
        store.closeCycle(prycd, CYCLE);
        vm.prank(openAvm);
        store.closeCycle(openAvm, CYCLE);
        vm.prank(regrid);
        store.closeCycle(regrid, CYCLE);
        vm.prank(eligibilityWriter);
        store.closeCycle(eligibilityWriter, CYCLE);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "a stale jurisdiction close refuses");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(), "stale close is region-unattested");
        _expect(aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED());
        _priceCall(aggregator, TOKEN_ID);
    }

    function test_region_invalidLocationZeroIsUnattested() public {
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, 0, CYCLE, false);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "value 0 refuses");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(), "value 0 is region-unattested");
        assertNotEq(failed, aggregator.CHECK_ELIGIBILITY_REGION(), "not an allow-list miss");
    }

    function test_region_reserved10IsUnattested() public {
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, US_MA_RESERVED, CYCLE, false);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "reserved 10 refuses");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(), "reserved 10 is region-unattested");
        assertNotEq(failed, aggregator.CHECK_ELIGIBILITY_VACANT_LAND(), "not a vacant-land miss");
    }

    function test_region_disallowedStateRefuses() public {
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, US_CA_VACANT, CYCLE, false);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "California refuses when only Massachusetts is allowed");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION(), "disallowed state is eligibility_region");
        _expect(aggregator.CHECK_ELIGIBILITY_REGION());
        _priceCall(aggregator, TOKEN_ID);
    }

    function test_region_disallowedCountryRefuses() public {
        uint128 country = _digest("country", "Canada");
        uint128 region = _digest("region", "Ontario");
        uint128 pack = (country << 65) | (region << 2) | 3;
        assertNotEq(country, US_DIGEST, "precondition: Canada is not the United States");
        assertGt(region, 0, "precondition: Ontario digest is non-zero");
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, pack, CYCLE, false);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "Canada refuses");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION(), "disallowed country is eligibility_region");
    }

    /// @notice A disallowed country whose region name is on the allow-list still refuses. Deleting
    ///         the country compare would price this pack, because the region digest matches.
    function test_region_disallowedCountryWithAllowedRegionNameRefuses() public {
        uint128 canada = _digest("country", "Canada");
        uint128 pack = (canada << 65) | (MA_DIGEST << 2) | 3;
        assertNotEq(canada, US_DIGEST, "precondition: Canada is not allowed");
        assertEq((pack >> 2) & ((uint128(1) << 63) - 1), MA_DIGEST, "precondition: the region name is allowed");
        assertEq(pack & 3, 3, "precondition: vacancy is vacant");
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, pack, CYCLE, false);
        (, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION(), "disallowed country with an allowed region name");
    }

    /// @notice Ruling 639155.2: an empty region list still refuses a disallowed country.
    function test_region_disallowedCountryOnEmptyAllowListRefuses() public {
        FabricaRegionRuleAggregator countryWide =
            new FabricaRegionRuleAggregator(_configWith("United States", new string[](0), jurisdictionWriter));
        uint128 canada = _digest("country", "Canada");
        uint128 ontario = _digest("region", "Ontario");
        uint128 pack = (canada << 65) | (ontario << 2) | 3;
        assertEq(countryWide.allowedRegionCount(), 0, "precondition: empty allow-list");
        assertNotEq(canada, countryWide.allowedCountryDigest(), "precondition: Canada is not allowed");
        assertGt(ontario, 0, "precondition: region digest is non-zero");
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, pack, CYCLE, false);
        (, bytes32 failed) = countryWide.eligibilityReport(usdc, TOKEN_ID);
        assertEq(failed, countryWide.CHECK_ELIGIBILITY_REGION(), "disallowed country on an empty allow-list");
    }

    /// @notice Non-zero country, region digest 0, vacancy 11, empty allow-list. Removing the
    ///         region-zero compare fail-opens: the empty list skips the allow-list.
    function test_region_zeroRegionDigestOnEmptyAllowListIsUnattested() public {
        FabricaRegionRuleAggregator countryWide =
            new FabricaRegionRuleAggregator(_configWith("United States", new string[](0), jurisdictionWriter));
        uint128 pack = (US_DIGEST << 65) | 3;
        assertEq(countryWide.allowedRegionCount(), 0, "precondition: empty allow-list");
        assertGt(US_DIGEST, 0, "precondition: country digest is non-zero");
        assertEq(pack >> 65, US_DIGEST, "precondition: the pack names the allowed country");
        assertEq((pack >> 2) & ((uint128(1) << 63) - 1), 0, "precondition: region digest is zero");
        assertEq(pack & 3, 3, "precondition: vacancy 11");
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, pack, CYCLE, false);
        (, bytes32 failed) = countryWide.eligibilityReport(usdc, TOKEN_ID);
        assertEq(
            failed,
            countryWide.CHECK_ELIGIBILITY_REGION_UNATTESTED(),
            "zero region digest on an empty allow-list is unattested"
        );
    }

    /// @notice Region-allow and vacant-land are both false. The allow-list return wins.
    function test_region_allowListWinsWhenVacantLandAlsoFails() public {
        uint128 california = _digest("region", "California");
        uint128 pack = (US_DIGEST << 65) | (california << 2) | 1;
        assertNotEq(california, MA_DIGEST, "precondition: California is not allowed");
        assertEq(pack & 3, 1, "precondition: vacancy is not vacant");
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, pack, CYCLE, false);
        (, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION(), "allow-list is checked before vacant-land");
    }

    /// @notice Reserved vacancy 10 on a disallowed country is unattested, not a country miss.
    function test_region_reservedVacancyBeatsDisallowedCountry() public {
        uint128 canada = _digest("country", "Canada");
        uint128 ontario = _digest("region", "Ontario");
        uint128 pack = (canada << 65) | (ontario << 2) | 2;
        assertNotEq(canada, US_DIGEST, "precondition: Canada is not allowed");
        assertGt(ontario, 0, "precondition: region digest is non-zero");
        assertGt(canada, 0, "precondition: country digest is non-zero");
        assertEq(pack & 3, 2, "precondition: reserved vacancy 10");
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, pack, CYCLE, false);
        (, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertEq(
            failed,
            aggregator.CHECK_ELIGIBILITY_REGION_UNATTESTED(),
            "reserved vacancy is checked before the country compare"
        );
    }

    function test_region_improvedRefusesAsVacantLand() public {
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, US_MA_IMPROVED, CYCLE, false);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "improved land refuses");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_VACANT_LAND(), "vacancy 01 is eligibility_vacant_land");
        _expect(aggregator.CHECK_ELIGIBILITY_VACANT_LAND());
        _priceCall(aggregator, TOKEN_ID);
    }

    function test_region_unknownVacancyRefusesAsVacantLand() public {
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, US_MA_UNKNOWN, CYCLE, false);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "unknown vacancy refuses");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_VACANT_LAND(), "vacancy 00 is eligibility_vacant_land");
    }

    function test_region_eng4327GateRunsBeforeRegion() public {
        uint256 token = TOKEN_ID + 2;
        _seedLivePrices(token);
        _writeJurisdiction(jurisdictionWriter, token, US_CA_VACANT, CYCLE, false);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, token);
        assertFalse(ok, "refused");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_UNATTESTED(), "ENG-4327 is named before the region gate");
        assertNotEq(failed, aggregator.CHECK_ELIGIBILITY_REGION(), "the region miss is not reached");
    }

    function test_region_regionRunsBeforeMaxSilence() public {
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, US_CA_VACANT, CYCLE, false);
        vm.warp(block.timestamp + MAX_SILENCE + 1);
        vm.prank(eligibilityWriter);
        store.closeCycle(eligibilityWriter, CYCLE);
        vm.prank(jurisdictionWriter);
        store.closeCycle(jurisdictionWriter, CYCLE);
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertFalse(ok, "refused");
        assertEq(failed, aggregator.CHECK_ELIGIBILITY_REGION(), "region is named before max_silence");
        assertNotEq(failed, aggregator.CHECK_MAX_SILENCE(), "dark price feeds are not the reported check");
    }

    function test_region_currencyRunsBeforeRegion() public {
        _writeJurisdiction(jurisdictionWriter, TOKEN_ID, US_CA_VACANT, CYCLE, false);
        address wrong = address(new RegionCurrencyStub());
        (bool ok, bytes32 failed) = aggregator.eligibilityReport(wrong, TOKEN_ID);
        assertFalse(ok, "refused");
        assertEq(failed, aggregator.CHECK_CURRENCY(), "currency is named before the region gate");
        _expect(aggregator.CHECK_CURRENCY());
        aggregator.price(address(this), wrong, _singleton(TOKEN_ID), _singleton(1), "");
    }

    /// @notice Wrong currency and no eligibility fact. Currency wins; swapping the two checks names
    ///         ENG-4327 instead.
    function test_region_currencyRunsBeforeEng4327() public {
        uint256 token = TOKEN_ID + 3;
        address wrong = address(new RegionCurrencyStub());
        (, bool live) = store.getLiveFact(eligibilityWriter, token, aggregator.KIND_ELIGIBILITY());
        assertFalse(live, "precondition: no eligibility fact");
        (, bytes32 failed) = aggregator.eligibilityReport(wrong, token);
        assertEq(failed, aggregator.CHECK_CURRENCY(), "currency is checked before ENG-4327");
    }

    /// @notice A live eligibility writer whose fact misses the mask. Deleting the mask compare
    ///         prices the token: jurisdiction and the price feeds already pass.
    function test_region_eligibilityMaskFailureIsTheWinningRefusal() public {
        _writeEligibility(TOKEN_ID, 1, CYCLE);
        (, bool live) = store.getLiveFact(eligibilityWriter, TOKEN_ID, aggregator.KIND_ELIGIBILITY());
        assertTrue(live, "precondition: the failing fact is live");
        assertTrue(
            store.isCycleValid(eligibilityWriter, store.lastCycleClose(eligibilityWriter).cycle),
            "precondition: the eligibility writer is live"
        );
        (, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertEq(failed, aggregator.CHECK_ELIGIBILITY(), "ENG-4327 mask failure is the winning refusal");
    }

    /// @notice The eligibility fact is live and passes the mask, but the writer's recorded close is
    ///         below its floor. Deleting the liveness compare prices the token.
    function test_region_eligibilityWriterLivenessIsTheWinningRefusal() public {
        _writeEligibilityFact(TOKEN_ID, ELIGIBILITY_PASS, CYCLE + 1);
        vm.prank(eligibilityWriter);
        store.setMinValidCycle(eligibilityWriter, CYCLE + 1);
        (, bool factLive) = store.getLiveFact(eligibilityWriter, TOKEN_ID, aggregator.KIND_ELIGIBILITY());
        assertTrue(factLive, "precondition: the eligibility fact is live");
        assertFalse(
            store.isCycleValid(eligibilityWriter, store.lastCycleClose(eligibilityWriter).cycle),
            "precondition: the recorded close is below the floor"
        );
        (, bytes32 failed) = aggregator.eligibilityReport(usdc, TOKEN_ID);
        assertEq(
            failed, aggregator.CHECK_ELIGIBILITY_UNATTESTED(), "eligibility-writer liveness is the winning refusal"
        );
    }

    function test_allowedRegionDigestAt_revertsOutOfBoundsIncludingEmptyList() public {
        vm.expectRevert(abi.encodeWithSelector(FabricaRegionRuleAggregator.RegionIndexOutOfBounds.selector, 1, 1));
        aggregator.allowedRegionDigestAt(1);
        FabricaRegionRuleAggregator countryWide =
            new FabricaRegionRuleAggregator(_configWith("United States", new string[](0), jurisdictionWriter));
        assertEq(countryWide.allowedRegionCount(), 0, "empty allow-list");
        vm.expectRevert(abi.encodeWithSelector(FabricaRegionRuleAggregator.RegionIndexOutOfBounds.selector, 0, 0));
        countryWide.allowedRegionDigestAt(0);
    }

    function test_constructor_twoRegionRoundTrip() public {
        FabricaRegionRuleAggregator two = new FabricaRegionRuleAggregator(
            _configWith("United States", _regions("California", "Massachusetts"), jurisdictionWriter)
        );
        uint128 california = _digest("region", "California");
        assertEq(two.allowedRegionCount(), 2, "two configured regions");
        assertEq(two.allowedRegionDigestAt(0), california, "slot 0 is California");
        assertEq(two.allowedRegionDigestAt(1), MA_DIGEST, "slot 1 is Massachusetts");
        assertNotEq(two.allowedRegionDigestAt(0), two.allowedRegionDigestAt(1), "the slots are distinct");
    }

    function _config() internal view returns (FabricaRegionRuleAggregator.Config memory) {
        return _configWith("United States", _regions("Massachusetts"), jurisdictionWriter);
    }

    function _configWith(string memory country, string[] memory regions, address writer)
        internal
        view
        returns (FabricaRegionRuleAggregator.Config memory)
    {
        address[] memory writerSet = new address[](3);
        writerSet[0] = prycd;
        writerSet[1] = openAvm;
        writerSet[2] = regrid;
        return FabricaRegionRuleAggregator.Config({
            factStore: address(store),
            usdc: usdc,
            writers: writerSet,
            eligibilityWriter: eligibilityWriter,
            requiredEligibilityMask: ELIGIBILITY_PASS,
            minLiveSources: MIN_LIVE_SOURCES,
            maxSilence: MAX_SILENCE,
            cycleCloseInterval: CYCLE_CLOSE_INTERVAL,
            seasoningWindow: SEASONING_WINDOW,
            maxJumpBps: MAX_JUMP_BPS,
            maxDispersionBps: MAX_DISPERSION_BPS,
            maxFirstPriceUsdc6: MAX_FIRST_PRICE_USDC6,
            valueCeilingUsdc6: VALUE_CEILING_USDC6,
            jurisdictionWriter: writer,
            allowedCountry: country,
            allowedRegions: regions
        });
    }

    function _seedSeasonedThenLive() internal {
        _write(store, prycd, TOKEN_ID, SEASONED_PRYCD, CYCLE);
        _write(store, openAvm, TOKEN_ID, SEASONED_OPENAVM, CYCLE);
        _write(store, regrid, TOKEN_ID, SEASONED_REGRID, CYCLE);
        vm.warp(block.timestamp + SEASONING_WINDOW + 1);
        _seedLivePrices(TOKEN_ID);
        vm.prank(prycd);
        store.closeCycle(prycd, CYCLE);
        vm.prank(openAvm);
        store.closeCycle(openAvm, CYCLE);
        vm.prank(regrid);
        store.closeCycle(regrid, CYCLE);
    }

    function _seedLivePrices(uint256 tokenId) internal {
        _write(store, prycd, tokenId, LIVE_PRYCD, CYCLE);
        _write(store, openAvm, tokenId, LIVE_OPENAVM, CYCLE);
        _write(store, regrid, tokenId, LIVE_REGRID, CYCLE);
    }

    function _write(FabricaFactStore target, address writer, uint256 tokenId, uint128 value, uint64 cycle) internal {
        FabricaFactStore.FactInput memory input = FabricaFactStore.FactInput({
            tokenId: tokenId,
            kind: target.KIND_PRICE(),
            value: value,
            confidence: CONFIDENCE,
            valuedAt: uint64(block.timestamp),
            cycle: cycle,
            data: keccak256(abi.encodePacked("eng4397-price", writer, tokenId, value, cycle))
        });
        vm.prank(writer);
        target.writeFact(writer, input);
    }

    function _writeEligibility(uint256 tokenId, uint128 value, uint64 cycle) internal {
        _writeEligibilityFact(tokenId, value, cycle);
        vm.prank(eligibilityWriter);
        store.closeCycle(eligibilityWriter, cycle);
    }

    function _writeEligibilityFact(uint256 tokenId, uint128 value, uint64 cycle) internal {
        FabricaFactStore.FactInput memory input = FabricaFactStore.FactInput({
            tokenId: tokenId,
            kind: aggregator.KIND_ELIGIBILITY(),
            value: value,
            confidence: 0,
            valuedAt: uint64(block.timestamp),
            cycle: cycle,
            data: keccak256(abi.encodePacked("eng4397-eligibility", tokenId, value, cycle))
        });
        vm.prank(eligibilityWriter);
        store.writeFact(eligibilityWriter, input);
    }

    function _writeJurisdiction(address writer, uint256 tokenId, uint128 value, uint64 cycle, bool close) internal {
        FabricaFactStore.FactInput memory input = FabricaFactStore.FactInput({
            tokenId: tokenId,
            kind: aggregator.KIND_JURISDICTION(),
            value: value,
            confidence: 0,
            valuedAt: uint64(block.timestamp),
            cycle: cycle,
            data: keccak256(abi.encodePacked("eng4397-jurisdiction", tokenId, value, cycle))
        });
        vm.prank(writer);
        store.writeFact(writer, input);
        if (close) {
            vm.prank(writer);
            store.closeCycle(writer, cycle);
        }
    }

    function _digest(string memory field, string memory name) internal pure returns (uint128) {
        return uint128(uint256(keccak256(bytes(string.concat("fabrica.jurisdiction.", field, ":", name)))) >> 193);
    }

    function _regions(string memory a) internal pure returns (string[] memory regions) {
        regions = new string[](1);
        regions[0] = a;
    }

    function _regions(string memory a, string memory b) internal pure returns (string[] memory regions) {
        regions = new string[](2);
        regions[0] = a;
        regions[1] = b;
    }

    function _price(FabricaRegionRuleAggregator target, uint256 tokenId) internal view returns (uint256) {
        return target.price(address(this), usdc, _singleton(tokenId), _singleton(1), "");
    }

    function _priceCall(FabricaRegionRuleAggregator target, uint256 tokenId) internal view {
        target.price(address(this), usdc, _singleton(tokenId), _singleton(1), "");
    }

    function _expect(bytes32 checkId) internal {
        vm.expectRevert(abi.encodeWithSelector(FabricaRegionRuleAggregator.CheckFailed.selector, checkId));
    }

    function _singleton(uint256 value) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = value;
    }

    function _assertDeployed(Vm.Log memory log) internal view {
        (
            address[] memory deployedWriters,
            uint128 mask,
            uint8 minLive,
            uint64 silence,
            uint64 interval,
            uint64 seasoning,
            uint16 jump,
            uint16 dispersion,
            uint128 firstPrice,
            uint128 ceiling
        ) = abi.decode(log.data, (address[], uint128, uint8, uint64, uint64, uint64, uint16, uint16, uint128, uint128));
        assertEq(address(uint160(uint256(log.topics[1]))), address(store), "AggregatorDeployed factStore");
        assertEq(address(uint160(uint256(log.topics[2]))), usdc, "AggregatorDeployed usdc");
        assertEq(address(uint160(uint256(log.topics[3]))), eligibilityWriter, "AggregatorDeployed eligibilityWriter");
        assertEq(deployedWriters[0], prycd, "AggregatorDeployed writer 0");
        assertEq(mask, ELIGIBILITY_PASS, "AggregatorDeployed mask");
        assertEq(minLive, MIN_LIVE_SOURCES, "AggregatorDeployed minLiveSources");
        assertEq(silence, MAX_SILENCE, "AggregatorDeployed maxSilence");
        assertEq(interval, CYCLE_CLOSE_INTERVAL, "AggregatorDeployed cycleCloseInterval");
        assertEq(seasoning, SEASONING_WINDOW, "AggregatorDeployed seasoningWindow");
        assertEq(jump, MAX_JUMP_BPS, "AggregatorDeployed maxJumpBps");
        assertEq(dispersion, MAX_DISPERSION_BPS, "AggregatorDeployed maxDispersionBps");
        assertEq(firstPrice, MAX_FIRST_PRICE_USDC6, "AggregatorDeployed maxFirstPrice");
        assertEq(ceiling, VALUE_CEILING_USDC6, "AggregatorDeployed valueCeiling");
    }

    function _decodeRegionRule(bytes memory data)
        internal
        pure
        returns (string memory country, uint128 countryDigest, string memory region, uint128 regionDigest)
    {
        string[] memory regions;
        uint128[] memory regionDigests;
        (country, countryDigest, regions, regionDigests) = abi.decode(data, (string, uint128, string[], uint128[]));
        region = regions[0];
        regionDigest = regionDigests[0];
    }
}
