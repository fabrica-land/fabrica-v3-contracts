// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {FabricaAttributeOracle} from "../src/FabricaAttributeOracle.sol";

/// @notice ENG-3913 per-operation gas bench for the fact store as deployed today.
/// @dev Measurement only: adds no production code and changes no deployed source.
///
///      **One scenario per test function, deliberately.** Foundry runs `setUp` and each
///      test as separate top-level calls, so a test body starts with a fresh access list
///      and no dirty storage slots — the same conditions a real transaction starts in.
///      Measuring several scenarios inside one test would let the first write warm and
///      dirty the slots the next one touches, and EIP-2200's dirty-slot discount would
///      report a repeat write at ~100 gas per slot instead of ~2,900. Every "repeat" or
///      "steady state" scenario is therefore primed in `setUp` and measured in its own
///      test, and each scenario gets its own validator id so one bench's per-validator
///      heartbeat cycle counter cannot constrain another's.
///
///      Each scenario reports three components so a transaction total can be built
///      without assuming anything:
///        - callGas:     `gasleft()` delta around the CALL into the fact store.
///        - overheadGas: the identical measurement against a codeless address, so the
///                       CALL-opcode share of `callGas` is measured, not assumed. The
///                       control has no code at all, so it contributes no call frame of
///                       its own and nothing is over-subtracted; a control contract with
///                       even an empty fallback costs 133 gas to enter, and subtracting
///                       that put every figure 133 gas below `forge test --gas-report`.
///        - calldataGas: EIP-2028 cost of the exact calldata (4/zero byte, 16/non-zero).
///      txTotalGas = 21,000 (EIP-2 intrinsic) + calldataGas + (callGas - overheadGas).
///
///      The fact store's account is warmed with an immutable read before each
///      measurement, because a real transaction's `to` address is warm on entry; the
///      storage the operation touches is left cold, as it is in a real transaction.
///
///      Knobs are `FabricaAttributeOracle.defaultKnobs()` — the exact config
///      `script/FabricaAttributeOracleDeploy.s.sol` deploys with, via
///      `_defaultKnobsFromContractRuntime()`.
contract Eng3913OracleGasBench is Test {
    FabricaAttributeOracle internal oracle;
    /// @dev Codeless control address for the CALL-overhead measurement. See `_overheadGas`.
    address internal noop;

    address internal owner;
    address internal publisher;
    address internal relayer;
    /// @dev One relayed signer per scenario. `writePriceRelayed` writes
    ///      `nonces[publisher]`, so a signer whose nonce is still zero pays a cold
    ///      zero -> non-zero store that a signer in steady state does not. Sharing one
    ///      signer would have put every relayed scenario in the first-write regime.
    uint256 internal relayedPkNew = 0xA11CE;
    uint256 internal relayedPk2nd = 0xB0B;
    uint256 internal relayedPkMid = 0xD00D;
    uint256 internal relayedPkWrapped = 0xC0FFEE;

    uint8 internal constant SRC = 0;
    uint128 internal constant PRICE = 100_000e6;
    /// @dev A moved price, inside the +15% / -50% write band, for the realistic case
    ///      where a source's valuation actually changed since the previous cycle.
    uint128 internal constant PRICE_MOVED = 104_000e6;
    uint64 internal constant DEADLINE = 1_700_000_000 + 3650 days;

    // One validator id per scenario. See the contract-level note.
    uint256 internal constant V_REG_FRESH = 5;
    uint256 internal constant V_REG = 6;
    uint256 internal constant V_PRICE_NEW = 7;
    uint256 internal constant V_PRICE_2ND = 8;
    uint256 internal constant V_PRICE_MID = 17;
    uint256 internal constant V_PRICE_WRAPPED = 9;
    uint256 internal constant V_REL_NEW = 10;
    uint256 internal constant V_REL_2ND = 11;
    uint256 internal constant V_REL_MID = 18;
    uint256 internal constant V_REL_WRAPPED = 12;
    uint256 internal constant V_ATTR_NEW = 13;
    uint256 internal constant V_ATTR_REPEAT = 14;
    uint256 internal constant V_HB_NEW = 15;
    uint256 internal constant V_HB_REPEAT = 16;

    uint256 internal constant TOKEN = 4_242_424;
    bytes32 internal constant ATTRIBUTE_ID = keccak256("landUse");

    /// @dev Relayed calldata is built in `setUp`, never in a test body: reading
    ///      `nonces(publisher)` to build a signature would warm a storage slot that
    ///      `writePriceRelayed` then writes, understating the measured write.
    bytes internal relayedNewCalldata;
    bytes internal relayed2ndCalldata;
    bytes internal relayedMidCalldata;
    bytes internal relayedWrappedCalldata;

    function setUp() public {
        vm.warp(1_700_000_000);
        owner = makeAddr("owner");
        publisher = makeAddr("publisher");
        relayer = makeAddr("relayer");

        noop = makeAddr("callOverheadControl");
        oracle = new FabricaAttributeOracle(owner, _deployKnobs());

        vm.startPrank(owner);
        oracle.setSourceEnabled(SRC, true);
        uint256[14] memory validators = [
            V_REG_FRESH,
            V_REG,
            V_PRICE_NEW,
            V_PRICE_2ND,
            V_PRICE_MID,
            V_PRICE_WRAPPED,
            V_REL_NEW,
            V_REL_2ND,
            V_REL_MID,
            V_REL_WRAPPED,
            V_ATTR_NEW,
            V_ATTR_REPEAT,
            V_HB_NEW,
            V_HB_REPEAT
        ];
        for (uint256 i; i < validators.length; ++i) {
            oracle.setPricePublisher(validators[i], publisher, true);
            oracle.setPricePublisher(validators[i], vm.addr(relayedPkNew), true);
            oracle.setPricePublisher(validators[i], vm.addr(relayedPk2nd), true);
            oracle.setPricePublisher(validators[i], vm.addr(relayedPkMid), true);
            oracle.setPricePublisher(validators[i], vm.addr(relayedPkWrapped), true);
        }
        // V_REG already holds one token, so `register:subsequent` and every
        // `registerBatch` measurement sees a non-zero `nextIndex`, as a backfill would.
        oracle.register(V_REG, 1);
        // Every price / attribute scenario writes to a token that is already registered,
        // and to a validator whose heartbeat slots are already non-zero — the state a
        // live oracle writer is in. The one-time cost of bootstrapping a validator is
        // measured separately as `heartbeat:first`.
        oracle.register(V_PRICE_NEW, TOKEN);
        oracle.register(V_PRICE_2ND, TOKEN);
        oracle.register(V_PRICE_MID, TOKEN);
        oracle.register(V_PRICE_WRAPPED, TOKEN);
        oracle.register(V_REL_NEW, TOKEN);
        oracle.register(V_REL_2ND, TOKEN);
        oracle.register(V_REL_MID, TOKEN);
        oracle.register(V_REL_WRAPPED, TOKEN);
        oracle.register(V_ATTR_NEW, TOKEN);
        oracle.register(V_ATTR_REPEAT, TOKEN);
        vm.stopPrank();

        vm.startPrank(publisher);
        oracle.heartbeat(V_PRICE_NEW, 1);
        oracle.heartbeat(V_PRICE_2ND, 1);
        oracle.heartbeat(V_PRICE_MID, 1);
        oracle.heartbeat(V_PRICE_WRAPPED, 1);
        oracle.heartbeat(V_REL_NEW, 1);
        oracle.heartbeat(V_REL_2ND, 1);
        oracle.heartbeat(V_REL_MID, 1);
        oracle.heartbeat(V_REL_WRAPPED, 1);
        oracle.heartbeat(V_HB_REPEAT, 1);
        // One prior price so the next write is the second: the first history ring slot
        // is still zero, so pushing to it is a cold zero -> non-zero store.
        oracle.writePrice(_params(V_PRICE_2ND, PRICE, 2));
        // Two prior writes: the ring's slot 0 now holds an entry and `_historyCount` is
        // already non-zero, so the next write allocates a *fresh* slot while paying only
        // a warm update on the counter. This is regime three, and it is where a row lives
        // for its writes 3 through `historyDepth`.
        oracle.writePrice(_params(V_PRICE_MID, PRICE, 2));
        vm.warp(block.timestamp + 2 hours);
        oracle.writePrice(_params(V_PRICE_MID, PRICE, 3));
        // Fill the ring past `historyDepth` so the next write lands on a slot that
        // already holds an entry. Every write after the first `historyDepth` writes for
        // a (validator, token, source) is in this regime, so it is the one the monthly
        // model runs on.
        _fillRing(V_PRICE_WRAPPED);
        vm.stopPrank();

        _primeRelayed();

        vm.prank(publisher);
        oracle.writeAttribute(V_ATTR_REPEAT, TOKEN, ATTRIBUTE_ID, bytes32(uint256(1)), 2, _prov(publisher, 2));
    }

    // -------------------------------------------------------------------------
    // Scenarios — one measured call per test
    // -------------------------------------------------------------------------

    function test_gas_register_firstUnderValidator() public {
        // The first token ever registered under a validator id also allocates that
        // validator's `nextIndex` counter (a zero -> non-zero store).
        _record("register:first under validator", abi.encodeCall(oracle.register, (V_REG_FRESH, TOKEN)), owner);
    }

    function test_gas_register_subsequent() public {
        // Every token after the first under the same validator. This is the regime a
        // 100k-token backfill runs in.
        _record("register:subsequent", abi.encodeCall(oracle.register, (V_REG, TOKEN)), owner);
    }

    function test_gas_registerBatch_1() public {
        _recordBatch(1);
    }

    function test_gas_registerBatch_10() public {
        _recordBatch(10);
    }

    function test_gas_registerBatch_100() public {
        _recordBatch(100);
    }

    function test_gas_registerBatch_1000() public {
        _recordBatch(1000);
    }

    function test_gas_writePrice_first() public {
        // First price for a (validator, token, source): every `SourcePrice` slot goes
        // zero -> non-zero and no history entry is pushed.
        _record("writePrice:first", abi.encodeCall(oracle.writePrice, (_params(V_PRICE_NEW, PRICE, 2))), publisher);
    }

    function test_gas_writePrice_second() public {
        vm.warp(block.timestamp + 2 hours);
        _record(
            "writePrice:second (ring slot cold)",
            abi.encodeCall(oracle.writePrice, (_params(V_PRICE_2ND, PRICE_MOVED, 3))),
            publisher
        );
    }

    function test_gas_writePrice_midRing() public {
        // Writes 3 through `historyDepth`: a fresh ring slot each time (cold zero ->
        // non-zero on both words of the `HistoryEntry`) but a warm `_historyCount`.
        // At weekly cadence a row stays in this regime for its first eleven months.
        vm.warp(block.timestamp + 2 hours);
        _record(
            "writePrice:writes 3-48 (ring slot fresh, counter warm)",
            abi.encodeCall(oracle.writePrice, (_params(V_PRICE_MID, PRICE_MOVED, 4))),
            publisher
        );
    }

    function test_gas_writePrice_wrappedMoved() public {
        vm.warp(block.timestamp + 2 hours);
        _record(
            "writePrice:write 49+ (ring wrapped), price moved",
            abi.encodeCall(oracle.writePrice, (_params(V_PRICE_WRAPPED, PRICE_MOVED, 100))),
            publisher
        );
    }

    function test_gas_writePrice_wrappedUnchanged() public {
        // A cycle in which the source republished the same valuation. NOT cheaper: this
        // measures the same gas as the moved case, because `priceUsdc6` is packed with
        // `valuedAt` in one `SourcePrice` word and with the ring entry's own `valuedAt` in
        // one `HistoryEntry` word, and `valuedAt` moves on every write. There is no
        // contract-side saving from an unchanged price; the only saving is not sending the
        // transaction. Kept as its own scenario precisely to demonstrate that.
        vm.warp(block.timestamp + 2 hours);
        _record(
            "writePrice:write 49+ (ring wrapped), price unchanged",
            abi.encodeCall(oracle.writePrice, (_params(V_PRICE_WRAPPED, PRICE, 100))),
            publisher
        );
    }

    function test_gas_writePriceRelayed_first() public {
        _record("writePriceRelayed:first", relayedNewCalldata, relayer);
    }

    function test_gas_writePriceRelayed_second() public {
        vm.warp(block.timestamp + 2 hours);
        _record("writePriceRelayed:second (ring slot cold)", relayed2ndCalldata, relayer);
    }

    function test_gas_writePriceRelayed_wrapped() public {
        vm.warp(block.timestamp + 2 hours);
        _record("writePriceRelayed:write 49+ (ring wrapped), price moved", relayedWrappedCalldata, relayer);
    }

    function test_gas_writePriceRelayed_midRing() public {
        vm.warp(block.timestamp + 2 hours);
        _record("writePriceRelayed:writes 3-48 (ring slot fresh, counter warm)", relayedMidCalldata, relayer);
    }

    function test_gas_writeAttribute_first() public {
        _record(
            "writeAttribute:first",
            abi.encodeCall(
                oracle.writeAttribute, (V_ATTR_NEW, TOKEN, ATTRIBUTE_ID, bytes32(uint256(1)), 2, _prov(publisher, 2))
            ),
            publisher
        );
    }

    function test_gas_writeAttribute_repeatChanged() public {
        _record(
            "writeAttribute:repeat, value changed",
            abi.encodeCall(
                oracle.writeAttribute, (V_ATTR_REPEAT, TOKEN, ATTRIBUTE_ID, bytes32(uint256(2)), 3, _prov(publisher, 3))
            ),
            publisher
        );
    }

    function test_gas_writeAttribute_repeatUnchanged() public {
        // Re-stamping an unchanged attribute with a new cycle number: the value word is
        // written back unchanged, so only the cycle word actually moves.
        _record(
            "writeAttribute:repeat, value unchanged",
            abi.encodeCall(
                oracle.writeAttribute, (V_ATTR_REPEAT, TOKEN, ATTRIBUTE_ID, bytes32(uint256(1)), 3, _prov(publisher, 3))
            ),
            publisher
        );
    }

    function test_gas_heartbeat_first() public {
        // Bootstrapping a validator: `lastHeartbeatAt` and `lastHeartbeatCycle` both go
        // zero -> non-zero. A once-per-validator cost, not a recurring one.
        _record("heartbeat:first", abi.encodeCall(oracle.heartbeat, (V_HB_NEW, 1)), publisher);
    }

    function test_gas_heartbeat_repeat() public {
        vm.warp(block.timestamp + 2 hours);
        _record("heartbeat:repeat", abi.encodeCall(oracle.heartbeat, (V_HB_REPEAT, 2)), publisher);
    }

    // -------------------------------------------------------------------------
    // Measurement primitives
    // -------------------------------------------------------------------------

    function _record(string memory name, bytes memory data, address sender) internal {
        // Belt and braces on the cold-storage claim: Foundry already gives a test body a
        // fresh access list, so nothing `setUp` touched is warm here, but `vm.cool` makes
        // that explicit rather than relied upon. It is a no-op if the isolation holds --
        // and if it ever stops holding, these numbers move and the change is visible.
        vm.cool(address(oracle));
        // Warm the fact store's account without touching any of its storage
        // (`historyDepth` is immutable, so the getter reads none): a real transaction's
        // `to` address is warm on entry, but its storage is not.
        oracle.historyDepth();
        uint256 overhead = _overheadGas(data, sender);
        uint256 callGas = _callGas(address(oracle), data, sender);
        require(callGas > overhead, "overhead exceeds call gas");
        uint256 execGas = callGas - overhead;
        uint256 cdGas = _calldataGas(data);
        console2.log(
            string.concat(
                "ENG3913ROW,",
                name,
                ",",
                vm.toString(callGas),
                ",",
                vm.toString(overhead),
                ",",
                vm.toString(execGas),
                ",",
                vm.toString(data.length),
                ",",
                vm.toString(cdGas),
                ",",
                vm.toString(21_000 + cdGas + execGas)
            )
        );
    }

    function _recordBatch(uint256 n) internal {
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = 9_000_000 + i;
        }
        _record(
            string.concat("registerBatch:", vm.toString(n)), abi.encodeCall(oracle.registerBatch, (V_REG, ids)), owner
        );
    }

    function _callGas(address target, bytes memory data, address sender) internal returns (uint256 used) {
        vm.prank(sender);
        uint256 before = gasleft();
        (bool ok,) = target.call(data);
        used = before - gasleft();
        require(ok, "bench call reverted");
    }

    function _overheadGas(bytes memory data, address sender) internal returns (uint256 used) {
        // Warm the control address first so it is measured warm, exactly as the fact
        // store is. A call to a codeless address executes no frame, so what is left is
        // the CALL opcode plus the caller-side memory and calldata cost -- precisely the
        // part of `callGas` a real transaction does not pay.
        (bool warm,) = noop.call(data);
        require(warm, "control warm-up reverted");
        vm.prank(sender);
        uint256 before = gasleft();
        (bool ok,) = noop.call(data);
        used = before - gasleft();
        require(ok, "control call reverted");
    }

    /// @notice EIP-2028 calldata gas: 4 per zero byte, 16 per non-zero byte.
    function _calldataGas(bytes memory data) internal pure returns (uint256 total) {
        for (uint256 i; i < data.length; ++i) {
            total += data[i] == 0 ? 4 : 16;
        }
    }

    // -------------------------------------------------------------------------
    // Priming helpers (all run in `setUp`, never in a measured test body)
    // -------------------------------------------------------------------------

    function _fillRing(uint256 validatorId) internal {
        uint8 depth = oracle.historyDepth();
        uint64 cycle = 4;
        for (uint256 i; i < uint256(depth) + 2; ++i) {
            oracle.writePrice(_params(validatorId, PRICE, cycle));
            cycle += 1;
            vm.warp(block.timestamp + 2 hours);
        }
    }

    function _primeRelayed() internal {
        // The genuinely first relayed write by this signer: its nonce is still zero.
        relayedNewCalldata = _relayedCalldata(relayedPkNew, V_REL_NEW, PRICE, 2);
        // One prior price on V_REL_2ND, written through the relayed path by the same
        // signer so its nonce is non-zero by the time the measured write lands.
        vm.prank(relayer);
        (bool ok2nd,) = address(oracle).call(_relayedCalldata(relayedPk2nd, V_REL_2ND, PRICE, 2));
        require(ok2nd, "relayed 2nd priming reverted");
        vm.warp(block.timestamp + 2 hours);
        relayed2ndCalldata = _relayedCalldata(relayedPk2nd, V_REL_2ND, PRICE_MOVED, 3);
        // V_REL_MID: two prior writes through the relayed path, so both the ring slot
        // allocation and the signer's non-zero nonce are in the regime-three state.
        vm.prank(relayer);
        (bool okMidA,) = address(oracle).call(_relayedCalldata(relayedPkMid, V_REL_MID, PRICE, 2));
        require(okMidA, "relayed mid priming A reverted");
        vm.warp(block.timestamp + 2 hours);
        vm.prank(relayer);
        (bool okMidB,) = address(oracle).call(_relayedCalldata(relayedPkMid, V_REL_MID, PRICE, 3));
        require(okMidB, "relayed mid priming B reverted");
        vm.warp(block.timestamp + 2 hours);
        relayedMidCalldata = _relayedCalldata(relayedPkMid, V_REL_MID, PRICE_MOVED, 4);
        // V_REL_WRAPPED: fill the ring through the direct path, then one relayed write so
        // the steady signer's nonce is non-zero too.
        vm.startPrank(publisher);
        _fillRing(V_REL_WRAPPED);
        vm.stopPrank();
        vm.prank(relayer);
        (bool okSteady,) = address(oracle).call(_relayedCalldata(relayedPkWrapped, V_REL_WRAPPED, PRICE, 99));
        require(okSteady, "relayed steady priming reverted");
        vm.warp(block.timestamp + 2 hours);
        relayedWrappedCalldata = _relayedCalldata(relayedPkWrapped, V_REL_WRAPPED, PRICE_MOVED, 100);
    }

    function _relayedCalldata(uint256 pk, uint256 validatorId, uint128 price, uint64 cycle)
        internal
        view
        returns (bytes memory)
    {
        address signer = vm.addr(pk);
        FabricaAttributeOracle.PriceWriteParams memory params = _params(validatorId, price, cycle);
        params.provenance.signer = signer;
        uint256 nonce = oracle.nonces(signer);
        bytes32 digest = oracle.hashPriceWrite(params, nonce, DEADLINE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodeCall(oracle.writePriceRelayed, (params, nonce, DEADLINE, abi.encodePacked(r, s, v)));
    }

    function _params(uint256 validatorId, uint128 price, uint64 cycle)
        internal
        view
        returns (FabricaAttributeOracle.PriceWriteParams memory)
    {
        return FabricaAttributeOracle.PriceWriteParams({
            validatorId: validatorId,
            tokenId: TOKEN,
            sourceId: SRC,
            priceUsdc6: price,
            confidenceScore: 500,
            valuedAt: uint64(block.timestamp),
            cycle: cycle,
            provenance: _prov(publisher, uint256(cycle))
        });
    }

    /// @notice Provenance for one write, with hashes that differ from every other write.
    /// @dev `seed` matters more than it looks. A real oracle writer's `rawPayloadHash` and
    ///      `inputsHash` change on every cycle, because they hash that cycle's payload and
    ///      inputs. An earlier version of this bench reused one pair of constant hashes,
    ///      so those two storage words were written back with the values they already held
    ///      -- 100 gas apiece under EIP-2200 instead of ~2,900 -- and every repeat-write
    ///      figure came out about 5,600 gas low. Vary them, or the model understates the
    ///      recurring cost of every price write.
    function _prov(address signer, uint256 seed) internal view returns (FabricaAttributeOracle.Provenance memory) {
        return FabricaAttributeOracle.Provenance({
            rawPayloadHash: keccak256(abi.encodePacked("raw", seed)),
            inputsHash: keccak256(abi.encodePacked("inputs", seed)),
            timestamp: uint64(block.timestamp),
            signer: signer
        });
    }

    function _deployKnobs() internal returns (FabricaAttributeOracle.KnobConfig memory) {
        FabricaAttributeOracle bootstrap = new FabricaAttributeOracle(owner, _bootstrapKnobs());
        return bootstrap.defaultKnobs();
    }

    function _bootstrapKnobs() internal pure returns (FabricaAttributeOracle.KnobConfig memory) {
        return FabricaAttributeOracle.KnobConfig({
            maxUpBps: 1500,
            maxDownBps: 5000,
            maxFirstPriceUsdc6: 50_000_000e6,
            maxSilence: 24 hours,
            minWriteInterval: 1 hours,
            registrySeasonDelay: 1 days,
            valueCeilingUsdc6: 50_000_000e6,
            historyDepth: 48
        });
    }
}
