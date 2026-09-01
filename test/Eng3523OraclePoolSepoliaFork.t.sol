// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import {Eng3519LaunchPoolSepoliaForkTest, ILaunchPool} from "./Eng3519LaunchPoolSepoliaFork.t.sol";
import {FabricaAttributeOracle} from "../src/FabricaAttributeOracle.sol";
import {FabricaOracleAggregator} from "../src/FabricaOracleAggregator.sol";

interface ILaunchPoolLifecycle {
    function refinance(
        bytes calldata encodedLoanReceipt,
        uint256 principal,
        uint64 duration,
        uint256 maxRepayment,
        uint128[] calldata ticks,
        bytes calldata options
    ) external returns (uint256);
    function repay(bytes calldata encodedLoanReceipt) external returns (uint256);
    function liquidate(bytes calldata encodedLoanReceipt) external;
}

/// @notice ENG-3523 — oracle-pool invariant suite on the live Sepolia launch-pool fork.
/// @dev Extends the ENG-3519 harness instead of re-copying the deployed-address and pool-creation proof.
contract Eng3523OraclePoolSepoliaForkTest is Eng3519LaunchPoolSepoliaForkTest {
    uint128 internal constant UNIT_PRICE_USDC6 = 1e6;
    uint128 internal constant ONE_HUNDRED_X_PRICE_USDC6 = 100e6;
    uint256 internal constant HALF_LTV_BPS = 5000;
    uint256 internal constant UNIT_FIXTURE_DEPOSIT = 60_000e6;
    uint256 internal constant UNIT_CAP_SEARCH = 60_000e6;
    uint64 internal constant NEXT_CYCLE = CYCLE + 1;

    address internal recoveryWriter = makeAddr("eng3523-recovery-writer");

    function test_units_rejectsNonUsdcAndPoolDrawUsesUsdc6Price() public {
        bytes memory currencyRevert =
            abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, aggregator.CHECK_CURRENCY());
        vm.expectRevert(currencyRevert);
        aggregator.price(FABRICA_TOKEN, makeAddr("not-usdc"), _singleton(COLLATERAL_TOKEN_ID), _singleton(1), "");

        (,, address unitPool) = _deployPricedFixture(COLLATERAL_TOKEN_ID, UNIT_PRICE_USDC6, 0);
        uint256 ratioCapacity = _maxBorrowable(unitPool, TICK_RATIO, UNIT_CAP_SEARCH);
        assertEq(
            ratioCapacity, (UNIT_PRICE_USDC6 * HALF_LTV_BPS) / 10_000, "USDC-6 oracle price must not be 1e18-scaled"
        );
        assertEq(ratioCapacity, 500_000, "1 USDC unit price at 50% LTV sources 0.5 USDC");
    }

    function test_writeTimeBand_blocksOutOfBandAndAllowsOnlyPerIntervalDrift() public {
        uint64 interval = factStore.minWriteInterval();
        uint16 maxUpBps = factStore.maxUpBps();
        uint128 startPrice = _sourcePrice(factStore, COLLATERAL_TOKEN_ID, SOURCE_PRYCD);
        uint128 tooHigh = uint128((uint256(startPrice) * (10_000 + maxUpBps + 1)) / 10_000);

        vm.warp(block.timestamp + interval + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaAttributeOracle.BandExceeded.selector, startPrice, tooHigh, maxUpBps, factStore.maxDownBps()
            )
        );
        _writePriceAt(factStore, COLLATERAL_TOKEN_ID, SOURCE_PRYCD, tooHigh, CYCLE);

        uint128 previous = startPrice;
        for (uint256 i; i < 3; ++i) {
            uint128 next = uint128((uint256(previous) * (10_000 + maxUpBps)) / 10_000);
            vm.warp(block.timestamp + interval + 1);
            _writePriceAt(factStore, COLLATERAL_TOKEN_ID, SOURCE_PRYCD, next, CYCLE);
            uint128 stored = _sourcePrice(factStore, COLLATERAL_TOKEN_ID, SOURCE_PRYCD);
            assertLe(stored, uint128((uint256(previous) * (10_000 + maxUpBps)) / 10_000), "drift > band");
            assertEq(stored, next, "in-band write stores exact price");
            previous = stored;
        }

        uint256 freshToken = COLLATERAL_TOKEN_ID + 3523;
        vm.prank(oracleOwner);
        factStore.register(VALIDATOR_ID, freshToken);
        uint128 aboveFirst = factStore.maxFirstPriceUsdc6() + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaAttributeOracle.FirstPriceTooHigh.selector, aboveFirst, factStore.maxFirstPriceUsdc6()
            )
        );
        _writePriceAt(factStore, freshToken, SOURCE_PRYCD, aboveFirst, CYCLE);
    }

    function test_seasoning_blocksNewTokenBorrowAndPublisherCannotRegister() public {
        uint256 freshToken = COLLATERAL_TOKEN_ID + 7_001;

        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", publisher));
        vm.prank(publisher);
        factStore.register(VALIDATOR_ID, freshToken);

        vm.prank(oracleOwner);
        factStore.register(VALIDATOR_ID, freshToken);
        _writeBothSourcesAt(factStore, freshToken, 10_000e6, 10_000e6, CYCLE);

        bytes memory registryRevert =
            abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, aggregator.CHECK_REGISTRY());
        vm.expectRevert(registryRevert);
        _quoteRatio(launchPool, freshToken, PRINCIPAL);

        vm.warp(block.timestamp + factStore.registrySeasonDelay() + 1);
        vm.prank(publisher);
        factStore.heartbeat(VALIDATOR_ID, CYCLE);
        assertGt(_quoteRatio(launchPool, freshToken, PRINCIPAL), PRINCIPAL, "seasoned token quotes again");
    }

    function test_deadManSwitch_blocksNewDebtRestoresOnHeartbeatAndLeavesExitsLive() public {
        (bytes memory repayReceipt, uint256 repayAmount) = _originateAndCaptureReceipt(PRINCIPAL);
        uint256 maxRepaymentBeforeSilence = _quoteRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL);

        vm.warp(block.timestamp + factStore.maxSilence() + 1);
        bytes memory heartbeatRevert =
            abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, aggregator.CHECK_HEARTBEAT());

        vm.expectRevert(heartbeatRevert);
        _quoteRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL);

        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155(FABRICA_TOKEN).setApprovalForAll(launchPool, true);
        vm.expectRevert(heartbeatRevert);
        _borrowRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL, maxRepaymentBeforeSilence);
        vm.expectRevert(heartbeatRevert);
        ILaunchPoolLifecycle(launchPool)
            .refinance(repayReceipt, PRINCIPAL, _borrowDuration(), maxRepaymentBeforeSilence, _ticks(TICK_RATIO), "");
        vm.stopPrank();

        deal(USDC, COLLATERAL_HOLDER, repayAmount * 2, true);
        vm.startPrank(COLLATERAL_HOLDER);
        IERC20(USDC).approve(launchPool, repayAmount * 2);
        uint256 repaid = ILaunchPoolLifecycle(launchPool).repay(repayReceipt);
        vm.stopPrank();
        assertGe(repaid, PRINCIPAL, "repay exits despite dead heartbeat");

        vm.prank(publisher);
        factStore.heartbeat(VALIDATOR_ID, CYCLE);
        (bytes memory liquidationReceipt,) = _originateAndCaptureReceipt(PRINCIPAL);
        vm.warp(block.timestamp + _launchDurations()[0] + factStore.maxSilence() + 1);
        ILaunchPoolLifecycle(launchPool).liquidate(liquidationReceipt);

        vm.prank(publisher);
        factStore.heartbeat(VALIDATOR_ID, CYCLE);
        assertGt(_quoteRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL), PRINCIPAL, "heartbeat restores quotes");
    }

    function test_recoveryStatusGate_blocksImmediatelyAndVoidIsIrreversible() public {
        vm.startPrank(oracleOwner);
        factStore.setRecoveryWriter(VALIDATOR_ID, recoveryWriter, true);
        vm.stopPrank();

        bytes memory recoveryRevert =
            abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, aggregator.CHECK_RECOVERY());
        uint8 distressed = factStore.RECOVERY_DISTRESSED();
        uint8 normal = factStore.RECOVERY_NORMAL();
        uint8 voided = factStore.RECOVERY_VOID();

        vm.prank(recoveryWriter);
        factStore.setRecoveryStatus(VALIDATOR_ID, COLLATERAL_TOKEN_ID, distressed);
        vm.expectRevert(recoveryRevert);
        _quoteRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL);

        vm.prank(recoveryWriter);
        factStore.setRecoveryStatus(VALIDATOR_ID, COLLATERAL_TOKEN_ID, normal);
        assertGt(
            _quoteRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL), PRINCIPAL, "Normal recovery restores borrow path"
        );

        vm.prank(recoveryWriter);
        factStore.setRecoveryStatus(VALIDATOR_ID, COLLATERAL_TOKEN_ID, voided);
        vm.expectRevert(recoveryRevert);
        _quoteRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL);

        vm.prank(recoveryWriter);
        vm.expectRevert(FabricaAttributeOracle.VoidIsIrreversible.selector);
        factStore.setRecoveryStatus(VALIDATOR_ID, COLLATERAL_TOKEN_ID, normal);
        vm.expectRevert(recoveryRevert);
        _quoteRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL);
    }

    function test_invalidationKillSwitchBlocksSameBlockAndLazyRewriteRestores() public {
        bytes memory minSourcesRevert =
            abi.encodeWithSelector(FabricaOracleAggregator.CheckFailed.selector, aggregator.CHECK_MIN_SOURCES());

        vm.prank(oracleOwner);
        factStore.setMinValidCycle(VALIDATOR_ID, NEXT_CYCLE);
        vm.expectRevert(minSourcesRevert);
        _quoteRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL);

        vm.warp(block.timestamp + factStore.minWriteInterval() + 1);
        _writePriceAt(factStore, COLLATERAL_TOKEN_ID, SOURCE_PRYCD, PRICE_PRYCD, NEXT_CYCLE);
        _writePriceAt(factStore, COLLATERAL_TOKEN_ID, SOURCE_OPENAVM, PRICE_OPENAVM, NEXT_CYCLE);
        assertGt(
            _quoteRatio(launchPool, COLLATERAL_TOKEN_ID, PRINCIPAL), PRINCIPAL, "lazy cycle rewrite restores token"
        );
    }

    function test_tickBehavior_absoluteLimitIgnoresHundredXPriceRatioScales() public {
        (,, address unitPool) = _deployPricedFixture(COLLATERAL_TOKEN_ID, UNIT_PRICE_USDC6, 0);
        (,, address hundredXPool) = _deployPricedFixture(COLLATERAL_TOKEN_ID, ONE_HUNDRED_X_PRICE_USDC6, 0);

        uint256 absoluteUnit = _maxBorrowable(unitPool, TICK_ABSOLUTE, UNIT_CAP_SEARCH);
        uint256 absoluteHundredX = _maxBorrowable(hundredXPool, TICK_ABSOLUTE, UNIT_CAP_SEARCH);
        uint256 ratioUnit = _maxBorrowable(unitPool, TICK_RATIO, UNIT_CAP_SEARCH);
        uint256 ratioHundredX = _maxBorrowable(hundredXPool, TICK_RATIO, UNIT_CAP_SEARCH);

        assertEq(absoluteUnit, absoluteHundredX, "absolute-limit tick must ignore oracle price");
        assertEq(absoluteUnit, 50_000e6, "absolute fixture remains tick-bound");
        assertEq(ratioUnit, (UNIT_PRICE_USDC6 * HALF_LTV_BPS) / 10_000, "unit ratio draw");
        assertEq(ratioHundredX, ratioUnit * 100, "ratio-limit tick scales with price");
    }

    function test_timelockSurface_setPriceOracleUnavailableRenouncedLooseningRevertsTighteningApplies() public {
        address priceOracleBefore = ILaunchPool(launchPool).priceOracle();
        vm.prank(ILaunchPool(launchPool).admin());
        (bool setOracleOk,) =
            launchPool.call(abi.encodeWithSignature("setPriceOracle(address)", makeAddr("unexpected-oracle")));
        assertFalse(setOracleOk, "live 2.15 rejects immediate oracle repoint selector");
        assertEq(ILaunchPool(launchPool).priceOracle(), priceOracleBefore, "live 2.15 has no immediate oracle repoint");

        uint64 seasoningWindow = aggregator.seasoningWindow();
        uint16 loosenedMaxJumpBps = aggregator.maxJumpBps() + 1;
        uint16 maxDispersionBps = aggregator.maxDispersionBps();
        uint8 minLiveSources = aggregator.minLiveSources();
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", oracleOwner));
        vm.prank(oracleOwner);
        aggregator.setKnobs(seasoningWindow, loosenedMaxJumpBps, maxDispersionBps, minLiveSources);

        uint16 tightenedUp = factStore.maxUpBps() - 1;
        uint16 maxDownBps = factStore.maxDownBps();
        uint128 maxFirstPriceUsdc6 = factStore.maxFirstPriceUsdc6();
        uint64 maxSilence = factStore.maxSilence();
        uint64 minWriteInterval = factStore.minWriteInterval();
        uint64 registrySeasonDelay = factStore.registrySeasonDelay();
        uint128 valueCeilingUsdc6 = factStore.valueCeilingUsdc6();
        vm.prank(oracleOwner);
        factStore.setKnobs(
            tightenedUp,
            maxDownBps,
            maxFirstPriceUsdc6,
            maxSilence,
            minWriteInterval,
            registrySeasonDelay,
            valueCeilingUsdc6
        );
        assertEq(factStore.maxUpBps(), tightenedUp, "owner tightening applies instantly");
    }

    function test_gasSnapshots_perPropertyWriteHeartbeatInvalidation() public {
        uint256 freshToken = COLLATERAL_TOKEN_ID + 9_001;
        vm.prank(oracleOwner);
        factStore.register(VALIDATOR_ID, freshToken);

        uint256 gasBefore = gasleft();
        _writePriceAt(factStore, freshToken, SOURCE_PRYCD, 10_000e6, CYCLE);
        uint256 coldWriteGas = gasBefore - gasleft();

        vm.warp(block.timestamp + factStore.minWriteInterval() + 1);
        gasBefore = gasleft();
        uint128 warmPrice = uint128((uint256(10_000e6) * (10_000 + factStore.maxUpBps())) / 10_000);
        _writePriceAt(factStore, freshToken, SOURCE_PRYCD, warmPrice, CYCLE);
        uint256 warmWriteGas = gasBefore - gasleft();

        gasBefore = gasleft();
        vm.prank(publisher);
        factStore.heartbeat(VALIDATOR_ID, CYCLE);
        uint256 heartbeatGas = gasBefore - gasleft();

        gasBefore = gasleft();
        vm.prank(oracleOwner);
        factStore.setMinValidCycle(VALIDATOR_ID, NEXT_CYCLE);
        uint256 invalidationGas = gasBefore - gasleft();

        console.log("ENG-3523 gas: cold per-property write =", coldWriteGas);
        console.log("ENG-3523 gas: warm per-property write =", warmWriteGas);
        console.log("ENG-3523 gas: heartbeat =", heartbeatGas);
        console.log("ENG-3523 gas: invalidation =", invalidationGas);
        assertGt(coldWriteGas, warmWriteGas, "cold write should exceed warm write");
        assertLt(invalidationGas, coldWriteGas, "cycle invalidation must be a single cheap owner write");
    }

    function _deployPricedFixture(uint256 tokenId, uint128 priceUsdc6, uint64 seasoningWindow)
        internal
        returns (FabricaAttributeOracle store, FabricaOracleAggregator agg, address pool)
    {
        store = _deployStore(0, 0);
        vm.startPrank(oracleOwner);
        store.setPricePublisher(VALIDATOR_ID, publisher, true);
        store.register(VALIDATOR_ID, tokenId);
        vm.stopPrank();
        _writeBothSourcesAt(store, tokenId, priceUsdc6, priceUsdc6, CYCLE);
        agg = _deployRenouncedAggregatorForStore(store, seasoningWindow);
        pool = _createLaunchPool(address(agg));
        _fundAndDepositAmount(pool, UNIT_FIXTURE_DEPOSIT);
    }

    function _deployStore(uint64 registrySeasonDelay, uint64 minWriteInterval)
        internal
        returns (FabricaAttributeOracle store)
    {
        FabricaAttributeOracle bootstrap = new FabricaAttributeOracle(oracleOwner, _bootstrapKnobs());
        FabricaAttributeOracle.KnobConfig memory knobs = bootstrap.defaultKnobs();
        knobs.registrySeasonDelay = registrySeasonDelay;
        knobs.minWriteInterval = minWriteInterval;
        store = new FabricaAttributeOracle(oracleOwner, knobs);
    }

    function _writeBothSourcesAt(
        FabricaAttributeOracle store,
        uint256 tokenId,
        uint128 prycdPrice,
        uint128 openAvmPrice,
        uint64 cycle
    ) internal {
        _writePriceAt(store, tokenId, SOURCE_PRYCD, prycdPrice, cycle);
        _writePriceAt(store, tokenId, SOURCE_OPENAVM, openAvmPrice, cycle);
    }

    function _sourcePrice(FabricaAttributeOracle store, uint256 tokenId, uint8 sourceId)
        internal
        view
        returns (uint128)
    {
        FabricaAttributeOracle.SourcePrice memory source = store.getSourcePrice(VALIDATOR_ID, tokenId, sourceId);
        return source.priceUsdc6;
    }

    function _quoteRatio(address pool, uint256 tokenId, uint256 principal) internal view returns (uint256) {
        return _quoteLaunchPoolFor(pool, tokenId, _ticks(TICK_RATIO), principal);
    }

    function _borrowRatio(address pool, uint256 tokenId, uint256 principal, uint256 maxRepayment)
        internal
        returns (uint256)
    {
        return _borrowLaunchPoolFor(pool, tokenId, _ticks(TICK_RATIO), principal, maxRepayment);
    }

    function _originateAndCaptureReceipt(uint256 principal)
        internal
        returns (bytes memory encodedLoanReceipt, uint256 repayment)
    {
        uint256 quoted = _quoteRatio(launchPool, COLLATERAL_TOKEN_ID, principal);
        vm.startPrank(COLLATERAL_HOLDER);
        IERC1155(FABRICA_TOKEN).setApprovalForAll(launchPool, true);
        vm.recordLogs();
        repayment = _borrowRatio(launchPool, COLLATERAL_TOKEN_ID, principal, quoted);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();
        encodedLoanReceipt = _loanReceiptFromLogs(logs);
        assertGt(encodedLoanReceipt.length, 0, "LoanOriginated receipt captured");
    }

    function _loanReceiptFromLogs(Vm.Log[] memory logs) internal view returns (bytes memory) {
        (bool found, bytes memory loanOriginatedEventData) = _loanOriginatedLogData(logs, launchPool);
        if (found) return abi.decode(loanOriginatedEventData, (bytes));
        revert("LoanOriginated not found");
    }
}
