// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/interfaces/IPool.sol";
import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./concretes/TestRepayablePool.sol";
import "./concretes/TestERC721.sol";

/**
 * Sepolia-fork end-to-end test for ENG-3076: anyone can close out a loan
 * against Fabrica's forked MetaStreet pool, with the original borrower
 * receiving the collateral.
 *
 * Run with: forge test --match-contract MetaStreetPoolRepaySepoliaForkTest \
 *                       --fork-url $SEPOLIA_RPC_URL -vvv
 *
 * When run without --fork-url, the onlyFork modifier short-circuits each
 * test (Sepolia USDC bytecode is absent on the local 31337 chain). Mirrors
 * the skip pattern in MetaStreetPoolDepositForSepoliaForkTest.
 *
 * The pool is freshly deployed on the fork — there is no pre-existing
 * Fabrica-forked pool on Sepolia yet (that's the next ticket post-merge).
 * Real Sepolia USDC is used as the currency token to exercise the SafeERC20
 * dispatch path against production-shaped token bytecode (return-data
 * handling, decimals lookup) rather than a clean-room mock.
 */
contract MetaStreetPoolRepaySepoliaForkTest is Test {
    /* Circle's USDC on Sepolia (6 decimals). */
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;

    TestRepayablePool internal pool;
    TestERC721 internal nft;

    address internal lender = makeAddr("fork-lender");
    address internal borrower = makeAddr("fork-borrower");
    address internal thirdParty = makeAddr("fork-third-party");

    /* USDC scales by 10^12 inside Pool, so 1000-USDC tick limit becomes 1000e18 internally. */
    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint256 internal constant LENDER_DEPOSIT = 1000e6;
    uint256 internal constant PRINCIPAL = 100e6;
    uint64 internal constant DURATION = 7 days;
    uint256 internal constant NFT_ID = 1;

    modifier onlyFork() {
        if (USDC.code.length == 0) return;
        _;
    }

    function setUp() public {
        if (USDC.code.length == 0) return;

        nft = new TestERC721("Fork Test NFT", "fNFT");
        ERC20DepositTokenImplementation impl = new ERC20DepositTokenImplementation();
        pool = new TestRepayablePool(address(impl));

        uint64[] memory durations = new uint64[](1);
        durations[0] = DURATION;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        pool.initialize(USDC, durations, rates);

        /* Fund the lender + provide approval, then deposit liquidity at TICK. */
        deal(USDC, lender, LENDER_DEPOSIT);
        vm.prank(lender);
        _approve(USDC, address(pool), type(uint256).max);
        vm.prank(lender);
        pool.deposit(TICK, LENDER_DEPOSIT, 1);

        /* Mint collateral to the borrower and grant the pool transfer rights. */
        nft.mint(borrower, NFT_ID);
        vm.prank(borrower);
        nft.setApprovalForAll(address(pool), true);
    }

    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }

    function _balance(address who) internal view returns (uint256 bal) {
        (bool ok, bytes memory data) = USDC.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        bal = abi.decode(data, (uint256));
    }

    /* Borrow PRINCIPAL against the NFT as `borrower` and return the encoded
       loan receipt captured from the LoanOriginated event. */
    function _borrow() internal returns (bytes memory encodedLoanReceipt) {
        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        vm.recordLogs();
        vm.prank(borrower);
        pool.borrow(borrower, PRINCIPAL, DURATION, address(nft), NFT_ID, PRINCIPAL, ticks, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pool) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                encodedLoanReceipt = abi.decode(logs[i].data, (bytes));
                return encodedLoanReceipt;
            }
        }
        revert("LoanOriginated event not found");
    }

    function test_fork_borrower_self_repay() public onlyFork {
        bytes memory receipt = _borrow();
        vm.warp(block.timestamp + 1);

        deal(USDC, borrower, PRINCIPAL);
        vm.prank(borrower);
        _approve(USDC, address(pool), type(uint256).max);

        uint256 borrowerBefore = _balance(borrower);
        assertEq(nft.ownerOf(NFT_ID), address(pool), "pool holds collateral pre-repay");

        vm.prank(borrower);
        uint256 repaid = pool.repay(receipt);

        assertEq(repaid, PRINCIPAL, "repayment amount");
        assertEq(nft.ownerOf(NFT_ID), borrower, "collateral returned to borrower");
        assertEq(_balance(borrower), borrowerBefore - PRINCIPAL, "borrower paid");
    }

    function test_fork_third_party_repay_collateral_to_borrower() public onlyFork {
        bytes memory receipt = _borrow();
        vm.warp(block.timestamp + 1);

        deal(USDC, thirdParty, PRINCIPAL);
        vm.prank(thirdParty);
        _approve(USDC, address(pool), type(uint256).max);

        uint256 borrowerBefore = _balance(borrower);
        uint256 thirdPartyBefore = _balance(thirdParty);
        assertEq(nft.ownerOf(NFT_ID), address(pool), "pool holds collateral pre-repay");

        vm.prank(thirdParty);
        uint256 repaid = pool.repay(receipt);

        assertEq(repaid, PRINCIPAL, "repayment amount");
        /* Collateral lands at the ORIGINAL borrower, not the third party. */
        assertEq(nft.ownerOf(NFT_ID), borrower, "collateral returned to original borrower");
        /* Funds pulled from the third party, not the borrower. */
        assertEq(_balance(thirdParty), thirdPartyBefore - PRINCIPAL, "third party paid");
        assertEq(_balance(borrower), borrowerBefore, "borrower balance untouched");
    }

    function test_fork_third_party_repay_reverts_under_allowance() public onlyFork {
        bytes memory receipt = _borrow();
        vm.warp(block.timestamp + 1);

        deal(USDC, thirdParty, PRINCIPAL);
        vm.prank(thirdParty);
        _approve(USDC, address(pool), PRINCIPAL - 1);

        vm.prank(thirdParty);
        /* Real Sepolia USDC reverts on insufficient allowance — any revert
           is acceptable here, the contract must refuse to transfer. */
        vm.expectRevert();
        pool.repay(receipt);

        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral still escrowed");
    }

    function test_fork_third_party_repay_reverts_insufficient_balance() public onlyFork {
        bytes memory receipt = _borrow();
        vm.warp(block.timestamp + 1);

        /* Full allowance, only half the principal in tokens. */
        deal(USDC, thirdParty, PRINCIPAL / 2);
        vm.prank(thirdParty);
        _approve(USDC, address(pool), type(uint256).max);

        vm.prank(thirdParty);
        vm.expectRevert();
        pool.repay(receipt);

        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral still escrowed");
    }
}
