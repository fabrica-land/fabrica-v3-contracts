// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Eng3922HarnessBase} from "./Eng3922HarnessBase.sol";
import {BenchAggregatorBase} from "./BenchAggregatorBase.sol";
import {ArmEasPointer} from "./arms/ArmEasPointer.sol";
import {ArmEasContext} from "./arms/ArmEasContext.sol";
import {ArmOwnerlessStore} from "./arms/ArmOwnerlessStore.sol";
import {OwnerlessFactStore} from "./OwnerlessFactStore.sol";
import {RevocationRequest, RevocationRequestData} from "./eas/IEAS.sol";

/// @notice ENG-3922 — the behavioural claims: the lock end to end, and the keying gap.
/// @dev These are assertions, not gas measurements, so the gas guard's one-scenario rule does not
///      bind here; each test still exercises exactly one claim.
contract Eng3922BehaviourTest is Eng3922HarnessBase {
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
}
