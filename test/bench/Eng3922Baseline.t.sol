// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaOracleAggregator} from "../../src/FabricaOracleAggregator.sol";
import {FabricaAttributeOracle} from "../../src/FabricaAttributeOracle.sol";
import {IFabricaAttributeOracle} from "../../src/interfaces/IFabricaAttributeOracle.sol";

/// @notice ENG-3922 step 1 — the pre-registered baseline.
/// @dev Measures today's `FabricaOracleAggregator.price()` gas for a THREE-source read
///      against the live Sepolia round-1 fact store, on a fork. Nothing here writes to
///      Sepolia: the fork is local, the live contracts are read as deployed, and no
///      round-1 contract is modified or redeployed on chain.
///
///      The live aggregator 0x5426cA6559861F729a54954FE08e2C2aFDBBd1a1 is renounced with
///      sourceIds [0, 1] and seasoningWindow 0, so it cannot itself answer the
///      three-source question. This deploys a fresh instance of the SAME deployed
///      aggregator source, configured for three sources and the 24h seasoning window
///      from the 2 September call, reading the LIVE fact store.
contract Eng3922BaselineTest is Test {
    /// @notice Live Sepolia round-1 fact store (read-only here).
    address internal constant LIVE_FACT_STORE = 0xFfA7535eF090C9193f44399843a05b60808ffC0D;
    /// @notice Live Sepolia round-1 aggregator (read-only here; two-source, seasoning 0).
    address internal constant LIVE_AGGREGATOR = 0x5426cA6559861F729a54954FE08e2C2aFDBBd1a1;
    /// @notice USDC on Sepolia, the aggregator's only accepted currency.
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    /// @notice Collateral token (unused by the aggregator, passed through IPriceOracle).
    address internal constant SEPOLIA_COLLATERAL = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    /// @notice Fork pin. Recent Sepolia head at the time of measurement.
    uint256 internal constant FORK_BLOCK = 11_628_000;
    /// @notice Validator id the live feeds are published under.
    uint256 internal constant VALIDATOR_ID = 1;
    /// @notice The 2 September call's seasoning window.
    uint64 internal constant SEASONING_WINDOW = 24 hours;

    FabricaAttributeOracle internal store;
    address internal storeOwner;
    address internal writer = makeAddr("eng3922-writer");
    uint64 internal cycle = 100;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        store = FabricaAttributeOracle(LIVE_FACT_STORE);
        storeOwner = store.owner();
        vm.prank(storeOwner);
        store.setPricePublisher(VALIDATOR_ID, writer, true);
    }

    /// @notice Baseline: three-source `price()` with the seasoning walk at several depths.
    function test_baselineThreeSourcePriceGas() public {
        _skipIfNoFork();
        uint256[4] memory depths = [uint256(0), 1, 3, 7];
        for (uint256 d; d < depths.length; ++d) {
            uint256 tokenId = uint256(keccak256(abi.encode("eng3922-baseline", d)));
            FabricaOracleAggregator agg = _seedAndDeploy(tokenId, depths[d]);
            uint256 gasUsed = _measurePrice(agg, tokenId);
            emit log_named_uint(
                string.concat("baseline price() gas, 3 sources, seasoning walk depth ", vm.toString(depths[d])), gasUsed
            );
        }
    }

    /// @notice The live two-source aggregator, for reference against the three-source number.
    function test_liveTwoSourceAggregatorConfig() public {
        _skipIfNoFork();
        FabricaOracleAggregator live = FabricaOracleAggregator(LIVE_AGGREGATOR);
        assertEq(address(live.factStore()), LIVE_FACT_STORE, "live aggregator points at live fact store");
        assertEq(live.sourceIds().length, 2, "live aggregator reads two sources");
        assertEq(live.seasoningWindow(), 0, "live aggregator has seasoning disabled");
        assertTrue(live.renounced(), "live aggregator is renounced");
    }

    /// @notice Write-side baseline: today's custom-store `writePrice` and `heartbeat`.
    /// @dev Grounds the per-cycle write budget in the pass mark. First write allocates the
    ///      current-price slot; every repeat write also pushes the previous value into the
    ///      history ring, so the repeat cost is the one a weekly cycle actually pays.
    function test_baselineWriteGas() public {
        _skipIfNoFork();
        uint256 tokenId = uint256(keccak256("eng3922-baseline-write"));
        vm.prank(storeOwner);
        store.register(VALIDATOR_ID, tokenId);
        emit log_named_uint(
            "baseline writePrice gas, first write (no history push)", _measureWrite(tokenId, 0, 100_000e6)
        );
        vm.warp(block.timestamp + 1 hours);
        emit log_named_uint(
            "baseline writePrice gas, repeat write (history push)", _measureWrite(tokenId, 0, 101_000e6)
        );
        vm.warp(block.timestamp + 1 hours);
        emit log_named_uint(
            "baseline writePrice gas, repeat write 2 (warm ring slot)", _measureWrite(tokenId, 0, 102_000e6)
        );
        vm.cool(LIVE_FACT_STORE);
        vm.prank(writer);
        uint256 before = gasleft();
        store.heartbeat(VALIDATOR_ID, cycle++);
        emit log_named_uint("baseline heartbeat gas", before - gasleft());
    }

    function _measureWrite(uint256 tokenId, uint8 sourceId, uint128 priceUsdc6) internal returns (uint256) {
        // Each write is its own transaction on chain, so measure against cold storage.
        vm.cool(LIVE_FACT_STORE);
        uint256 before = gasleft();
        _write(tokenId, sourceId, priceUsdc6);
        // vm.prank inside _write is metered too; it is a cheat-code no-op on gas at this scale.
        return before - gasleft();
    }

    /// @notice Write-side baseline, second regime: the history ring after it has wrapped.
    /// @dev The live Sepolia store has never reached this. `historyDepth` is 48 and the deepest
    ///      row on chain has `historyLength` 2, so every write observed in the round-1 receipts
    ///      still allocated a fresh ring slot at zero->non-zero. Once a row passes 48 writes the
    ///      push overwrites a non-zero slot instead, and the cost drops. At one write per token
    ///      per oracle source per weekly cycle a row does not wrap for 48 weeks, so both regimes
    ///      are real and the budget has to say which one it means.
    function test_baselineWriteGasWrappedRing() public {
        _skipIfNoFork();
        uint256 tokenId = uint256(keccak256("eng3922-baseline-wrapped"));
        vm.prank(storeOwner);
        store.register(VALIDATOR_ID, tokenId);
        uint128 p = 100_000e6;
        // Fill past historyDepth (48) so the ring wraps. Prices stay inside the +15%/-50% band.
        for (uint256 i; i < 52; ++i) {
            vm.warp(block.timestamp + 1 hours);
            p = (i % 2 == 0) ? p + 100e6 : p - 100e6;
            _write(tokenId, 0, p);
        }
        assertEq(store.historyLength(VALIDATOR_ID, tokenId, 0), 48, "ring is full");
        vm.warp(block.timestamp + 1 hours);
        emit log_named_uint(
            "baseline writePrice gas, wrapped ring (overwrites a non-zero slot)", _measureWrite(tokenId, 0, p + 100e6)
        );
    }

    // -------------------------------------------------------------------------
    // Fixture
    // -------------------------------------------------------------------------

    /// @notice Register the token, publish `walkDepth + 1` in-window writes per source, deploy the aggregator.
    /// @param walkDepth How many history hops `_priceAsOf` must walk before it clears the seasoning cutoff.
    function _seedAndDeploy(uint256 tokenId, uint256 walkDepth) internal returns (FabricaOracleAggregator agg) {
        vm.prank(storeOwner);
        store.register(VALIDATOR_ID, tokenId);
        // The pre-seasoning baseline every source walks back to.
        _writeAll(tokenId, 100_000e6);
        // Age it past the seasoning cutoff so the walk has something to land on.
        vm.warp(block.timestamp + SEASONING_WINDOW + 1 hours);
        // In-window writes: each one adds a hop the seasoning walk must skip.
        for (uint256 i; i < walkDepth; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _writeAll(tokenId, uint128(100_000e6 + (i + 1) * 1_000e6));
        }
        vm.warp(block.timestamp + 1 hours);
        _writeAll(tokenId, uint128(100_000e6 + (walkDepth + 1) * 1_000e6));
        agg = new FabricaOracleAggregator(
            address(this),
            LIVE_FACT_STORE,
            SEPOLIA_USDC,
            VALIDATOR_ID,
            _threeSources(),
            SEASONING_WINDOW,
            5000,
            20_000,
            2
        );
        agg.renounceAggregator();
    }

    /// @notice One write per source, all three at the same price so dispersion never trips.
    function _writeAll(uint256 tokenId, uint128 priceUsdc6) internal {
        for (uint8 sid; sid < 3; ++sid) {
            _write(tokenId, sid, priceUsdc6);
        }
    }

    function _write(uint256 tokenId, uint8 sourceId, uint128 priceUsdc6) internal {
        FabricaAttributeOracle.Provenance memory prov = FabricaAttributeOracle.Provenance({
            rawPayloadHash: keccak256(abi.encode("raw", tokenId, sourceId, priceUsdc6)),
            inputsHash: keccak256(abi.encode("inputs", tokenId, sourceId, priceUsdc6)),
            timestamp: uint64(block.timestamp),
            signer: writer
        });
        vm.prank(writer);
        store.writePrice(
            FabricaAttributeOracle.PriceWriteParams({
                validatorId: VALIDATOR_ID,
                tokenId: tokenId,
                sourceId: sourceId,
                priceUsdc6: priceUsdc6,
                confidenceScore: 9000,
                valuedAt: uint64(block.timestamp),
                cycle: cycle++,
                provenance: prov
            })
        );
    }

    /// @notice Gas consumed inside a single-token, quantity-1 `price()` call.
    function _measurePrice(FabricaOracleAggregator agg, uint256 tokenId) internal returns (uint256) {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256[] memory qty = new uint256[](1);
        qty[0] = 1;
        // The seeding writes above warmed every slot `price()` reads. A pool calling
        // `price()` in its own transaction pays cold-access prices, so cool them back.
        vm.cool(LIVE_FACT_STORE);
        vm.cool(address(agg));
        uint256 before = gasleft();
        uint256 p = agg.price(SEPOLIA_COLLATERAL, SEPOLIA_USDC, ids, qty, "");
        uint256 spent = before - gasleft();
        require(p != 0, "price must be non-zero");
        return spent;
    }

    function _threeSources() internal pure returns (uint8[] memory ids) {
        ids = new uint8[](3);
        ids[0] = 0;
        ids[1] = 1;
        ids[2] = 2;
    }

    function _skipIfNoFork() internal {
        if (address(store) == address(0)) vm.skip(true);
    }
}
