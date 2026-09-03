// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FabricaOracleAggregator} from "../../src/FabricaOracleAggregator.sol";
import {FabricaAttributeOracle} from "../../src/FabricaAttributeOracle.sol";

/// @notice ENG-3922 step 1 — the pre-registered baseline.
/// @dev Measures today's `FabricaOracleAggregator.price()` gas for a THREE-source read against the
///      live Sepolia round-1 fact store, on a fork. Nothing here writes to Sepolia: the fork is
///      local, the live contracts are read as deployed, and no round-1 contract is modified or
///      redeployed on chain.
///
///      The live aggregator 0x5426cA6559861F729a54954FE08e2C2aFDBBd1a1 is renounced with
///      sourceIds [0, 1] and seasoningWindow 0, so it cannot itself answer the three-source
///      question. This deploys a fresh instance of the SAME deployed aggregator source, configured
///      for three oracle sources and the 24h seasoning window from the 2 September call.
///
///      Structured per the gas-measurement guard in CLAUDE.md: ONE scenario per test function,
///      shared priming in `setUp`, `vm.cool` immediately before the measured call, and no loop
///      emitting rows. Write-side numbers are quoted as whole-transaction gas (21,000 intrinsic +
///      EIP-2028 calldata + execution) because they are costs; the read is quoted as execution gas
///      because `price()` is a view a pool calls inside its own transaction and is never sent as
///      one — the ticket's "gas inside `price()`".
contract Eng3922BaselineTest is Test {
    /// @notice Live Sepolia round-1 fact store (read as deployed).
    address internal constant LIVE_FACT_STORE = 0xFfA7535eF090C9193f44399843a05b60808ffC0D;
    /// @notice Live Sepolia round-1 aggregator (two-source, seasoning 0, renounced).
    address internal constant LIVE_AGGREGATOR = 0x5426cA6559861F729a54954FE08e2C2aFDBBd1a1;
    address internal constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address internal constant SEPOLIA_COLLATERAL = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    uint256 internal constant FORK_BLOCK = 11_628_000;
    uint256 internal constant VALIDATOR_ID = 1;
    uint64 internal constant SEASONING_WINDOW = 24 hours;

    FabricaAttributeOracle internal store;
    address internal storeOwner;
    address internal writer = makeAddr("eng3922-writer");
    uint64 internal nextCycle;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // Select by the `sepolia` alias from foundry.toml rpc_endpoints, per the repo's fork-test
        // convention; `vm.envOr` above is only the skip decision.
        rpc;
        vm.createSelectFork("sepolia", FORK_BLOCK);
        forked = true;
        store = FabricaAttributeOracle(LIVE_FACT_STORE);
        storeOwner = store.owner();
        // The store's heartbeat cycle is per-validator and monotonic, so start above the live one.
        nextCycle = store.lastHeartbeatCycle(VALIDATOR_ID) + 1;
        vm.prank(storeOwner);
        store.setPricePublisher(VALIDATOR_ID, writer, true);
    }

    // -------------------------------------------------------------------------
    // Read side — the go/no-go number, one walk depth per test
    // -------------------------------------------------------------------------

    function test_readGasWalkDepth0() public {
        _reportRead(0);
    }

    function test_readGasWalkDepth1() public {
        _reportRead(1);
    }

    function test_readGasWalkDepth3() public {
        _reportRead(3);
    }

    function test_readGasWalkDepth7() public {
        _reportRead(7);
    }

    /// @notice The live two-source aggregator's configuration, for the record. No measurement.
    function test_liveTwoSourceAggregatorConfig() public view {
        if (!forked) return;
        FabricaOracleAggregator live = FabricaOracleAggregator(LIVE_AGGREGATOR);
        assertEq(address(live.factStore()), LIVE_FACT_STORE, "live aggregator points at live fact store");
        assertEq(live.sourceIds().length, 2, "live aggregator reads two oracle sources");
        assertEq(live.seasoningWindow(), 0, "live aggregator has seasoning disabled");
        assertTrue(live.renounced(), "live aggregator is renounced");
    }

    // -------------------------------------------------------------------------
    // Write side — one regime per test, whole-transaction gas
    // -------------------------------------------------------------------------

    /// @notice Write 1 on a row: allocates the current-price slots, pushes no history.
    function test_writeGasFirstWrite() public {
        if (!forked) vm.skip(true);
        uint256 tokenId = _register("first");
        _reportWrite("writePrice, write 1 of a row (no history push)", tokenId, 100_000e6);
    }

    /// @notice Write 2 on a row: the ring slot AND the counter both go zero to non-zero.
    function test_writeGasSecondWrite() public {
        if (!forked) vm.skip(true);
        uint256 tokenId = _register("second");
        _write(tokenId, 100_000e6);
        vm.warp(block.timestamp + 1 hours);
        _reportWrite("writePrice, write 2 of a row (ring slot and counter both cold)", tokenId, 101_000e6);
    }

    /// @notice Writes 3-48 on a row: the ring slot is fresh, the counter is already non-zero.
    function test_writeGasThirdWrite() public {
        if (!forked) vm.skip(true);
        uint256 tokenId = _register("third");
        _write(tokenId, 100_000e6);
        vm.warp(block.timestamp + 1 hours);
        _write(tokenId, 101_000e6);
        vm.warp(block.timestamp + 1 hours);
        _reportWrite("writePrice, writes 3-48 of a row (ring slot fresh, counter warm)", tokenId, 102_000e6);
    }

    /// @notice Write 49+ on a row: the ring has wrapped and the push overwrites a non-zero slot.
    /// @dev The live Sepolia store has never reached this. `historyDepth` is 48 and the deepest row
    ///      on chain has `historyLength` 2, so every write in the round-1 receipts is still in the
    ///      allocating regime. At one write per token per oracle source per weekly cycle a row does
    ///      not wrap for 48 weeks.
    function test_writeGasWrappedRing() public {
        if (!forked) vm.skip(true);
        uint256 tokenId = _register("wrapped");
        uint128 p = 100_000e6;
        for (uint256 i; i < 52; ++i) {
            vm.warp(block.timestamp + 1 hours);
            p = (i % 2 == 0) ? p + 100e6 : p - 100e6;
            _write(tokenId, p);
        }
        assertEq(store.historyLength(VALIDATOR_ID, tokenId, 0), 48, "ring is full");
        vm.warp(block.timestamp + 1 hours);
        _reportWrite("writePrice, write 49+ of a row (ring wrapped, slot overwritten)", tokenId, p + 100e6);
    }

    /// @notice The standalone cycle-close heartbeat.
    function test_writeGasHeartbeat() public {
        if (!forked) vm.skip(true);
        uint64 cycle = nextCycle++;
        bytes memory callData = abi.encodeCall(FabricaAttributeOracle.heartbeat, (VALIDATOR_ID, cycle));
        vm.cool(LIVE_FACT_STORE);
        vm.prank(writer);
        uint256 before = gasleft();
        store.heartbeat(VALIDATOR_ID, cycle);
        uint256 execution = before - gasleft();
        _emitCost("heartbeat", execution, callData);
    }

    // -------------------------------------------------------------------------
    // Fixture
    // -------------------------------------------------------------------------

    function _reportRead(uint256 walkDepth) internal {
        if (!forked) vm.skip(true);
        uint256 tokenId = _register(string.concat("read-", vm.toString(walkDepth)));
        // The pre-seasoning baseline the walk lands on.
        _writeAll(tokenId, 100_000e6);
        vm.warp(block.timestamp + SEASONING_WINDOW + 1 hours);
        // Each in-window republication is one more hop the walk has to skip.
        for (uint256 i; i < walkDepth; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _writeAll(tokenId, uint128(100_000e6 + (i + 1) * 1_000e6));
        }
        // A cycle close, so the feed is live. Without it a depth-0 read fails CHECK_HEARTBEAT:
        // the live store's maxSilence is one hour and the seeding warps 25.
        vm.prank(writer);
        store.heartbeat(VALIDATOR_ID, nextCycle++);
        FabricaOracleAggregator agg = new FabricaOracleAggregator(
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
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256[] memory qty = new uint256[](1);
        qty[0] = 1;
        // The seeding above warmed every slot `price()` reads; a pool calling it in its own
        // transaction pays cold-access prices.
        vm.cool(LIVE_FACT_STORE);
        vm.cool(address(agg));
        uint256 before = gasleft();
        uint256 p = agg.price(SEPOLIA_COLLATERAL, SEPOLIA_USDC, ids, qty, "");
        uint256 execution = before - gasleft();
        assertGt(p, 0, "price must be non-zero");
        emit log_named_uint(
            string.concat("price() execution gas, 3 oracle sources, seasoning walk depth ", vm.toString(walkDepth)),
            execution
        );
    }

    function _reportWrite(string memory label, uint256 tokenId, uint128 priceUsdc6) internal {
        bytes memory callData = abi.encodeCall(FabricaAttributeOracle.writePrice, (_params(tokenId, 0, priceUsdc6)));
        vm.cool(LIVE_FACT_STORE);
        vm.prank(writer);
        uint256 before = gasleft();
        store.writePrice(_params(tokenId, 0, priceUsdc6));
        uint256 execution = before - gasleft();
        _emitCost(label, execution, callData);
    }

    /// @notice Emit execution, intrinsic-plus-calldata, and the whole-transaction total.
    function _emitCost(string memory label, uint256 execution, bytes memory callData) internal {
        uint256 intrinsic = _intrinsicGas(callData);
        emit log_named_uint(string.concat(label, " -- execution gas"), execution);
        emit log_named_uint(string.concat(label, " -- intrinsic + calldata"), intrinsic);
        emit log_named_uint(string.concat(label, " -- WHOLE TRANSACTION"), execution + intrinsic);
    }

    /// @notice 21,000 plus EIP-2028 calldata: 4 gas per zero byte, 16 per non-zero.
    function _intrinsicGas(bytes memory callData) internal pure returns (uint256 g) {
        g = 21_000;
        for (uint256 i; i < callData.length; ++i) {
            g += callData[i] == 0 ? 4 : 16;
        }
    }

    function _register(string memory tag) internal returns (uint256 tokenId) {
        tokenId = uint256(keccak256(abi.encode("eng3922-baseline", tag)));
        vm.prank(storeOwner);
        store.register(VALIDATOR_ID, tokenId);
    }

    function _writeAll(uint256 tokenId, uint128 priceUsdc6) internal {
        uint64 cycle = nextCycle++;
        for (uint8 sid; sid < 3; ++sid) {
            vm.prank(writer);
            store.writePrice(_paramsWithCycle(tokenId, sid, priceUsdc6, cycle));
        }
    }

    function _write(uint256 tokenId, uint128 priceUsdc6) internal {
        vm.prank(writer);
        store.writePrice(_params(tokenId, 0, priceUsdc6));
    }

    function _params(uint256 tokenId, uint8 sourceId, uint128 priceUsdc6)
        internal
        returns (FabricaAttributeOracle.PriceWriteParams memory)
    {
        return _paramsWithCycle(tokenId, sourceId, priceUsdc6, nextCycle++);
    }

    function _paramsWithCycle(uint256 tokenId, uint8 sourceId, uint128 priceUsdc6, uint64 cycle)
        internal
        view
        returns (FabricaAttributeOracle.PriceWriteParams memory)
    {
        return FabricaAttributeOracle.PriceWriteParams({
            validatorId: VALIDATOR_ID,
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
                signer: writer
            })
        });
    }

    function _threeSources() internal pure returns (uint8[] memory ids) {
        ids = new uint8[](3);
        ids[0] = 0;
        ids[1] = 1;
        ids[2] = 2;
    }
}
