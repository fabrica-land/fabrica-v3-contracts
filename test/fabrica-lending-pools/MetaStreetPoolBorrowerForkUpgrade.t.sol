// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import "../../src/fabrica-lending-pools/Pool.sol";
import "../../src/fabrica-lending-pools/interfaces/IPool.sol";
import "../../src/fabrica-lending-pools/LoanReceipt.sol";
import "../../src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol";

import {UpgradeableBeacon} from "../../lib/openzeppelin-contracts-v4/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "../../lib/openzeppelin-contracts-v4/contracts/proxy/beacon/BeaconProxy.sol";

import "./concretes/TestLiquidatablePool.sol";
import "./concretes/MockCollateralLiquidator.sol";
import "./concretes/TestERC721.sol";

/**
 * ENG-3231 fork-upgrade-verify (directed by ED at gate time).
 *
 * Mirrors the REAL upgrade path for the Fabrica lending pool — an
 * UpgradeableBeacon whose implementation is a Pool concrete, fronted by a
 * BeaconProxy pool instance (the production topology; see
 * FabricaLendingPoolStackDeploy.s.sol / FabricaLendingPoolUpgrade.s.sol) —
 * against production-shaped currency (real USDC) on BOTH target chains:
 *
 *   - Sepolia:  MetaStreetPoolBorrowerForkUpgradeSepoliaTest  (--fork-url $SEPOLIA_RPC_URL)
 *   - Mainnet:  MetaStreetPoolBorrowerForkUpgradeMainnetTest  (--fork-url $MAINNET_RPC_URL)
 *
 * setUp: deploy a Pool impl (forge auto-deploys + links the NEW BorrowLogic /
 * DepositLogic from this branch), put it behind an UpgradeableBeacon, create a
 * BeaconProxy pool, seed lender liquidity in real USDC, then deploy a SECOND
 * new impl and `beacon.upgradeTo(...)` it — exactly the deploy→repoint sequence
 * the real upgrade runs. Every test below executes against the upgraded
 * BeaconProxy pool, so all dispatch flows through the new libraries
 * (delegatecall: proxy → impl → external library) over the proxy's storage.
 *
 * TestLiquidatablePool (permissive collateral filter + trivial rate model,
 * repayment == principal) stands in for WeightedRateERC1155CollectionPool so
 * borrow() needs no signed oracle quote — it is the same Pool base linking the
 * same BorrowLogic/DepositLogic, so the borrower-param + LP-dispatch code under
 * test is identical. The deployable concrete's EIP-170 fit is verified
 * separately by `forge clean && forge build --sizes` (full graph, no --skip:
 * 23,628 B, 948 under).
 *
 * The onlyFork modifier short-circuits when the chain's USDC bytecode is absent
 * (i.e. run without the matching --fork-url), mirroring the existing fork tests.
 */
abstract contract MetaStreetPoolBorrowerForkUpgradeBase is Test {
    /* Mirror ERC20 Transfer for the deposit-token wrapper event checks. */
    event Transfer(address indexed from, address indexed to, uint256 value);

    TestLiquidatablePool internal pool;
    UpgradeableBeacon internal beacon;
    address internal implA;
    address internal implB;
    TestERC721 internal nft;
    MockCollateralLiquidator internal liquidator;
    ERC20DepositTokenImplementation internal depositTokenImpl;

    address internal lender = makeAddr("fork-lender");
    /* Caller / router: owns the collateral, funds the purchase, takes principal. */
    address internal router = makeAddr("fork-router");
    /* Designated borrower-of-record / beneficial owner. */
    address internal designated = makeAddr("fork-designated");
    address internal stranger = makeAddr("fork-stranger");

    /* USDC scales by 10^12 inside Pool; 1000-USDC tick limit becomes 1000e18 internally. */
    uint128 internal constant TICK = uint128(uint256(1000 ether) << 8);
    uint256 internal constant LENDER_DEPOSIT = 1000e6;
    uint256 internal constant PRINCIPAL = 100e6;
    uint64 internal constant DURATION = 7 days;
    uint64 internal constant GRACE_PERIOD = 20 days;
    uint256 internal constant NFT_ID = 1;

    function _usdc() internal pure virtual returns (address);

    modifier onlyFork() {
        if (_usdc().code.length == 0) return;
        _;
    }

    function setUp() public {
        if (_usdc().code.length == 0) return;
        nft = new TestERC721("Fork Test NFT", "fNFT");
        depositTokenImpl = new ERC20DepositTokenImplementation();
        liquidator = new MockCollateralLiquidator();
        /* Impl A: forge auto-deploys + links the NEW BorrowLogic / DepositLogic. */
        implA = address(new TestLiquidatablePool(address(depositTokenImpl), address(liquidator), GRACE_PERIOD));
        /* Production topology: UpgradeableBeacon + BeaconProxy (this contract is the beacon owner). */
        beacon = new UpgradeableBeacon(implA);
        uint64[] memory durations = new uint64[](1);
        durations[0] = DURATION;
        uint64[] memory rates = new uint64[](1);
        rates[0] = uint64(uint256(0.1e18) / 365 days);
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,uint64[],uint64[])", _usdc(), durations, rates);
        pool = TestLiquidatablePool(address(new BeaconProxy(address(beacon), initData)));
        /* Seed lender liquidity in real USDC BEFORE the upgrade (state must survive it). */
        deal(_usdc(), lender, LENDER_DEPOSIT);
        vm.prank(lender);
        _approve(_usdc(), address(pool), type(uint256).max);
        vm.prank(lender);
        pool.deposit(TICK, LENDER_DEPOSIT, 1);
        /* The router owns the collateral (it funds the financed purchase). */
        nft.mint(router, NFT_ID);
        vm.prank(router);
        nft.setApprovalForAll(address(pool), true);
        /* Upgrade: deploy a second new impl and repoint the beacon — exactly the
           deploy→beacon.upgradeTo sequence FabricaLendingPoolUpgrade.s.sol runs. */
        implB = address(new TestLiquidatablePool(address(depositTokenImpl), address(liquidator), GRACE_PERIOD));
        beacon.upgradeTo(implB);
    }

    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }

    function _balance(address who) internal view returns (uint256 bal) {
        (bool ok, bytes memory data) = _usdc().staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        bal = abi.decode(data, (uint256));
    }

    function _shares(address account, uint128 tick) internal view returns (uint128 shares) {
        (shares,) = pool.deposits(account, tick);
    }

    /* Router borrows PRINCIPAL against its NFT, designating `borrowerOfRecord`. */
    function _borrowTo(address borrowerOfRecord) internal returns (bytes memory encodedLoanReceipt) {
        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;
        vm.recordLogs();
        vm.prank(router);
        pool.borrow(borrowerOfRecord, PRINCIPAL, DURATION, address(nft), NFT_ID, PRINCIPAL, ticks, "");
        return _findLoanReceipt(vm.getRecordedLogs());
    }

    function _findLoanReceipt(Vm.Log[] memory logs) internal view returns (bytes memory) {
        bytes32 topic = keccak256("LoanOriginated(bytes32,bytes)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter == address(pool) && entry.topics.length > 0 && entry.topics[0] == topic) {
                return abi.decode(entry.data, (bytes));
            }
        }
        revert("LoanOriginated event not found");
    }

    /* The beacon repoints to the new impl and the pre-upgrade deposit survives. */
    function test_fork_beacon_upgrade_preserves_state() public onlyFork {
        assertEq(beacon.implementation(), implB, "beacon repointed to new impl");
        assertTrue(implA != implB, "two distinct impls deployed");
        assertGt(_shares(lender, TICK), 0, "lender deposit (pre-upgrade) preserved across upgrade");
    }

    /* borrow(designated): borrower-of-record == designated; collateral from
       msg.sender (router); principal (real USDC) to msg.sender (router). */
    function test_fork_borrow_to_designated_borrower() public onlyFork {
        uint256 routerBefore = _balance(router);
        bytes memory receipt = _borrowTo(designated);
        LoanReceipt.LoanReceiptV2 memory lr = pool.decodeLoanReceipt(receipt);
        assertEq(lr.borrower, designated, "borrower-of-record is designated");
        assertEq(nft.ownerOf(NFT_ID), address(pool), "collateral escrowed from router");
        assertEq(_balance(router), routerBefore + PRINCIPAL, "principal (USDC) to msg.sender/router");
        assertEq(_balance(designated), 0, "designated borrower receives no principal");
    }

    /* repay returns the collateral to the designated borrower (not the payer/router). */
    function test_fork_repay_returns_collateral_to_designated() public onlyFork {
        bytes memory receipt = _borrowTo(designated);
        vm.warp(block.timestamp + 1);
        deal(_usdc(), stranger, PRINCIPAL);
        vm.prank(stranger);
        _approve(_usdc(), address(pool), type(uint256).max);
        vm.prank(stranger);
        uint256 repaid = pool.repay(receipt);
        assertEq(repaid, PRINCIPAL, "repayment amount");
        assertEq(nft.ownerOf(NFT_ID), designated, "collateral redeemed to designated borrower");
    }

    /* refinance is gated to the designated borrower and preserves borrower-of-record. */
    function test_fork_refinance_preserves_designated_borrower() public onlyFork {
        bytes memory receipt = _borrowTo(designated);
        vm.warp(block.timestamp + 1);
        uint128[] memory ticks = new uint128[](1);
        ticks[0] = TICK;
        /* Router (caller, not borrower-of-record) cannot refinance. */
        vm.prank(router);
        vm.expectRevert(IPool.InvalidCaller.selector);
        pool.refinance(receipt, PRINCIPAL, DURATION, PRINCIPAL, ticks, "");
        /* The designated borrower can, and the new loan keeps borrower == designated. */
        vm.recordLogs();
        vm.prank(designated);
        uint256 newRepayment = pool.refinance(receipt, PRINCIPAL, DURATION, PRINCIPAL, ticks, "");
        assertEq(newRepayment, PRINCIPAL, "refinanced repayment");
        LoanReceipt.LoanReceiptV2 memory lr = pool.decodeLoanReceipt(_findLoanReceipt(vm.getRecordedLogs()));
        assertEq(lr.borrower, designated, "refinance preserves designated borrower-of-record");
    }

    /* depositFor + redeem + rebalance dispatch through the new DepositLogic, which
       resolves the deposit token via its ERC-7201 slot mirror and fires the
       wrapper ERC20 Transfer hook — verified against real USDC on a tokenized tick. */
    function test_fork_lp_dispatch_hooks_via_new_depositlogic() public onlyFork {
        address wrapper = pool.tokenize(TICK);
        assertEq(wrapper, pool.depositToken(TICK), "tokenized wrapper matches accessor");
        deal(_usdc(), router, LENDER_DEPOSIT);
        vm.prank(router);
        _approve(_usdc(), address(pool), type(uint256).max);
        /* depositFor: mint hook (address(0) -> designated). */
        uint256 snap = vm.snapshotState();
        vm.prank(router);
        uint256 mintShares = pool.depositFor(designated, TICK, PRINCIPAL, 1);
        vm.revertToState(snap);
        vm.expectEmit(true, true, true, true, wrapper);
        emit Transfer(address(0), designated, mintShares);
        vm.prank(router);
        pool.depositFor(designated, TICK, PRINCIPAL, 1);
        /* redeem: burn hook (designated -> address(0)). */
        vm.expectEmit(true, true, true, true, wrapper);
        emit Transfer(designated, address(0), mintShares);
        vm.prank(designated);
        uint128 redemptionId = pool.redeem(TICK, mintShares);
        /* rebalance the processed redemption back into the same tokenized tick:
           mint hook (address(0) -> designated) on the new shares. */
        snap = vm.snapshotState();
        vm.prank(designated);
        (, uint256 newShares,) = pool.rebalance(TICK, TICK, redemptionId, 1);
        vm.revertToState(snap);
        vm.expectEmit(true, true, true, true, wrapper);
        emit Transfer(address(0), designated, newShares);
        vm.prank(designated);
        pool.rebalance(TICK, TICK, redemptionId, 1);
    }

    /* transfer()'s caller check moved into DepositLogic (resolved via the ERC-7201
       slot); a non-deposit-token caller still reverts InvalidCaller. */
    function test_fork_transfer_rejects_non_deposit_token_caller() public onlyFork {
        vm.expectRevert(IPool.InvalidCaller.selector);
        vm.prank(stranger);
        pool.transfer(stranger, designated, TICK, 1);
    }
}

contract MetaStreetPoolBorrowerForkUpgradeSepoliaTest is MetaStreetPoolBorrowerForkUpgradeBase {
    /* Circle's USDC on Sepolia (6 decimals). */
    function _usdc() internal pure override returns (address) {
        return 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    }
}

contract MetaStreetPoolBorrowerForkUpgradeMainnetTest is MetaStreetPoolBorrowerForkUpgradeBase {
    /* Circle's USDC on Ethereum mainnet (6 decimals). */
    function _usdc() internal pure override returns (address) {
        return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }
}
