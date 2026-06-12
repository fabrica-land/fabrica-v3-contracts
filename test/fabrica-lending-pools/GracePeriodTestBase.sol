// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "./concretes/TestLiquidatablePool.sol";
import "./concretes/TestERC721.sol";

/**
 * Shared scaffolding for the ENG-3113 liquidation grace-period tests (non-fork
 * and mainnet-fork). Holds the common constants, the borrow helper, and the
 * event signatures; each suite supplies its own currency token + funding in
 * setUp().
 */
abstract contract GracePeriodTestBase is Test {
    /* Mirror IPool events so vm.getRecordedLogs()/vm.expectEmit can match by topic. */
    event LoanOriginated(bytes32 indexed loanReceiptHash, bytes loanReceipt);
    event LoanLiquidated(bytes32 indexed loanReceiptHash);
    event LoanRepaid(bytes32 indexed loanReceiptHash, uint256 repayment);

    TestLiquidatablePool internal pool;
    TestERC721 internal nft;

    address internal borrower = makeAddr("grace-borrower");
    address internal liquidatorCaller = makeAddr("grace-liquidator-caller");

    /* TICK encodes limit=1000 ether, durIdx=0, rateIdx=0, type=Absolute. */
    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint64 internal constant DURATION = 7 days;
    uint64 internal constant GRACE_PERIOD = 20 days;
    uint256 internal constant NFT_ID = 1;

    /* Borrow `principal` against NFT_ID as `borrower`; return the encoded loan
       receipt and its hash, captured from the LoanOriginated event. */
    function _borrow(uint256 principal) internal returns (bytes memory encodedLoanReceipt, bytes32 loanReceiptHash) {
        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        vm.recordLogs();
        vm.prank(borrower);
        pool.borrow(borrower, principal, DURATION, address(nft), NFT_ID, principal, ticks, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pool) && logs[i].topics.length > 1 && logs[i].topics[0] == topic) {
                loanReceiptHash = logs[i].topics[1];
                /* Non-indexed bytes payload is abi.encode(bytes). */
                encodedLoanReceipt = abi.decode(logs[i].data, (bytes));
                return (encodedLoanReceipt, loanReceiptHash);
            }
        }
        revert("LoanOriginated event not found");
    }
}
