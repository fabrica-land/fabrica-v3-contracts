// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import "./concretes/TestERC20Variants.sol";
import "./concretes/TestERC721.sol";
import "./concretes/TestRepayablePool.sol";

/**
 * Branch coverage for the ENG-3076 edits to `Pool.repay`'s currency-token
 * pull. The happy path (transferFrom returns true) is exercised by every
 * test in `MetaStreetPoolRepay.t.sol`. The two non-happy branches of the
 * `require(currencyToken.transferFrom(msg.sender, address(this), unscaledRepayment))`
 * statement are exercised here:
 *
 *   E. transferFrom returns false  → require reverts (no implicit panic)
 *   F. transferFrom returns nothing → strict ABI decoder reverts
 *
 * Both branches must leave loan state unchanged so that the borrower's
 * collateral remains escrowed and the loan can still be repaid by an
 * ERC-20-compliant caller.
 */
contract MetaStreetPoolRepayBranchCoverage is Test {
    TestRepayablePool internal pool;
    TestERC721 internal nft;
    ERC20DepositTokenImplementation internal erc20DepositTokenImpl;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal thirdParty = makeAddr("third-party");

    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint256 internal constant LENDER_DEPOSIT = 1000 ether;
    uint256 internal constant PRINCIPAL = 100 ether;
    uint64 internal constant DURATION = 7 days;
    uint256 internal constant NFT_ID = 1;

    function setUp() public {
        nft = new TestERC721("Test NFT", "tNFT");
        erc20DepositTokenImpl = new ERC20DepositTokenImplementation();
        pool = new TestRepayablePool(address(erc20DepositTokenImpl));
        nft.mint(borrower, NFT_ID);
        vm.prank(borrower);
        nft.setApprovalForAll(address(pool), true);
    }

    function _initPoolAndBorrow(address currency) internal returns (bytes memory encodedLoanReceipt) {
        uint64[] memory durations = new uint64[](1);
        durations[0] = DURATION;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        pool.initialize(currency, durations, rates);

        // Lender deposits using `transfer` calls the pool issues internally.
        // The Pool.deposit path uses safeTransferFrom (unchanged by ENG-3076)
        // so it must work on both currency-token variants below — both implement
        // the deposit-side surface as the standard expects.
        _mint(currency, lender, LENDER_DEPOSIT);
        vm.prank(lender);
        _approve(currency, address(pool), type(uint256).max);
        vm.prank(lender);
        pool.deposit(TICK, LENDER_DEPOSIT, 1);

        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;

        vm.recordLogs();
        vm.prank(borrower);
        pool.borrow(borrower, PRINCIPAL, DURATION, address(nft), NFT_ID, PRINCIPAL, ticks, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pool) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                return abi.decode(logs[i].data, (bytes));
            }
        }
        revert("LoanOriginated event not found");
    }

    function _mint(address token, address to, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));
        require(ok, "mint failed");
    }

    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }

    /* Branch E: transferFrom returns false. The third party has the funds and
       has APPROVED the pool — but the currency token's transferFrom returns
       false on the actual call. Pool.repay's `require(transferFrom(...))`
       must catch the false and revert; collateral must remain escrowed. */
    function test_branchE_transferFromReturnsFalse_reverts() public {
        TestERC20ReturnsFalse currency = new TestERC20ReturnsFalse("Quirk", "QRK", 18);
        bytes memory receipt = _initPoolAndBorrow(address(currency));
        vm.warp(block.timestamp + 1);

        currency.mint(thirdParty, PRINCIPAL);
        vm.prank(thirdParty);
        currency.approve(address(pool), type(uint256).max);

        // Force the token to refuse the transfer by lowering allowance just
        // before the repay call (after the pool was approved for unlimited).
        // The token returns false instead of reverting on insufficient
        // allowance. This is what we want to exercise.
        vm.prank(thirdParty);
        currency.approve(address(pool), 0);

        assertEq(nft.ownerOf(NFT_ID), address(pool), "pool holds collateral pre-repay");

        vm.prank(thirdParty);
        vm.expectRevert(bytes("T"));
        pool.repay(receipt);

        // State is intact: pool still owns the collateral, third party still
        // holds their funds, allowance is still zero.
        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral still escrowed");
        assertEq(currency.balanceOf(thirdParty), PRINCIPAL, "third party funds unchanged");
        assertEq(currency.allowance(thirdParty, address(pool)), 0, "allowance still zero");
    }

    /* Branch F: transferFrom returns no value (USDT-style). Pool.repay calls
       IERC20.transferFrom which the Solidity compiler emits with an
       expected bool return type; the strict ABI decoder reverts on empty
       returndata. The revert is intentional safe-fail behavior — the entire
       point of CLAUDE.md's "supported currency tokens MUST return bool"
       warning. Loan must remain repayable through a compliant ERC-20 (so we
       also assert state is unchanged afterwards). */
    function test_branchF_transferFromNoReturnValue_reverts() public {
        TestERC20NoReturnValue currency = new TestERC20NoReturnValue("NoBool", "NBL", 18);
        bytes memory receipt = _initPoolAndBorrow(address(currency));
        vm.warp(block.timestamp + 1);

        currency.mint(thirdParty, PRINCIPAL);
        vm.prank(thirdParty);
        currency.approve(address(pool), type(uint256).max);

        assertEq(nft.ownerOf(NFT_ID), address(pool), "pool holds collateral pre-repay");

        // ABI-decode of empty returndata when bool was expected → revert.
        // We don't match a specific revert string; the EVM emits a panic-
        // style abi-decode error.
        vm.prank(thirdParty);
        vm.expectRevert();
        pool.repay(receipt);

        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral still escrowed");
        assertEq(currency.balanceOf(thirdParty), PRINCIPAL, "third party funds unchanged");
    }
}
