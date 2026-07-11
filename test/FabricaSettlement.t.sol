// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FabricaSettlement} from "../src/FabricaSettlement.sol";
import {ISettlementMorphoFlashLoanCallback} from "../src/interfaces/ISettlementMorpho.sol";
import {TestERC20} from "./fabrica-lending-pools/concretes/TestERC20.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    OfferItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/lib/ConsiderationStructs.sol";
import {ItemType, OrderType} from "seaport-types/lib/ConsiderationEnums.sol";

contract SettlementTest1155 is ERC1155("") {
    function mint(address to, uint256 id) external {
        _mint(to, id, 1, "");
    }
}

contract SettlementTestPool is ERC1155Holder {
    IERC20 public immutable currencyToken;
    SettlementTest1155 public immutable collateral;
    address public immutable borrower;
    uint256 public immutable tokenId;
    uint256 public payoff;
    bool public active = true;

    constructor(
        IERC20 currency_,
        SettlementTest1155 collateral_,
        address borrower_,
        uint256 tokenId_,
        uint256 payoff_
    ) {
        currencyToken = currency_;
        collateral = collateral_;
        borrower = borrower_;
        tokenId = tokenId_;
        payoff = payoff_;
    }

    function repay(bytes calldata) external {
        require(active, "inactive");
        active = false;
        currencyToken.transferFrom(msg.sender, address(this), payoff);
        collateral.safeTransferFrom(address(this), borrower, tokenId, 1, "");
    }
}

contract SettlementMaliciousPool {
    IERC20 public immutable currencyToken;
    uint256 public immutable payoff;

    constructor(IERC20 currency_, uint256 payoff_) {
        currencyToken = currency_;
        payoff = payoff_;
    }

    function repay(bytes calldata) external {
        currencyToken.transferFrom(msg.sender, address(this), payoff);
    }
}

contract SettlementTestMorpho {
    IERC20 public immutable token;
    bool public underpull;
    bool public doubleCallback;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setUnderpull(bool value) external {
        underpull = value;
    }

    function setDoubleCallback(bool value) external {
        doubleCallback = value;
    }

    function flashLoan(address tokenAddress, uint256 assets, bytes calldata data) external {
        require(tokenAddress == address(token), "token");
        token.transfer(msg.sender, assets);
        ISettlementMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        if (doubleCallback) {
            ISettlementMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);
        }
        token.transferFrom(msg.sender, address(this), underpull ? assets + 1 : assets);
    }

    function spoof(address target, uint256 assets, bytes calldata data) external {
        ISettlementMorphoFlashLoanCallback(target).onMorphoFlashLoan(assets, data);
    }
}

contract SettlementTestSeaport {
    IERC20 public immutable currency;
    SettlementTest1155 public immutable collateral;
    bool public reenter;
    FabricaSettlement public settlement;

    constructor(IERC20 currency_, SettlementTest1155 collateral_) {
        currency = currency_;
        collateral = collateral_;
    }

    function configureReentry(FabricaSettlement settlement_) external {
        settlement = settlement_;
        reenter = true;
    }

    function getCounter(address) external pure returns (uint256) {
        return 0;
    }

    function getOrderHash(OrderComponents calldata order) external pure returns (bytes32) {
        return keccak256(abi.encode(order.offerer, order.salt));
    }

    function fulfillAdvancedOrder(AdvancedOrder calldata order, CriteriaResolver[] calldata, bytes32, address recipient)
        external
        returns (bool)
    {
        if (order.extraData.length == 1) revert("Oracle signature expired");
        if (reenter) {
            vmReenter(order, recipient);
        }
        for (uint256 i; i < order.parameters.consideration.length; ++i) {
            ConsiderationItem calldata leg = order.parameters.consideration[i];
            currency.transferFrom(msg.sender, leg.recipient, leg.startAmount);
        }
        collateral.safeTransferFrom(
            order.parameters.offerer, recipient, order.parameters.offer[0].identifierOrCriteria, 1, ""
        );
        return true;
    }

    function vmReenter(AdvancedOrder calldata order, address recipient) private {
        settlement.settleAndBuy(order, address(1), "", recipient);
    }
}

contract FabricaSettlementTest is Test {
    uint256 internal constant PRICE = 100_000e6;
    uint256 internal constant FEE = 5_000e6;
    uint256 internal constant MAX_REPAYMENT = 22_000e6;
    uint256 internal constant PAYOFF = 21_000e6;
    uint256 internal constant TOKEN_ID = 42;

    address internal seller = makeAddr("seller");
    address internal buyer = makeAddr("buyer");
    address internal payer = makeAddr("coinflow relayer");
    address internal feeRecipient = makeAddr("fee recipient");
    TestERC20 internal usdc;
    SettlementTest1155 internal nft;
    SettlementTestPool internal pool;
    SettlementTestMorpho internal morpho;
    SettlementTestSeaport internal seaport;
    FabricaSettlement internal settlement;
    bytes internal receipt;

    function setUp() public {
        usdc = new TestERC20("Test USDC", "USDC", 6);
        nft = new SettlementTest1155();
        IERC20 currency = IERC20(address(usdc));
        pool = new SettlementTestPool(currency, nft, seller, TOKEN_ID, PAYOFF);
        morpho = new SettlementTestMorpho(currency);
        seaport = new SettlementTestSeaport(currency, nft);
        address[] memory initialPools = new address[](1);
        initialPools[0] = address(pool);
        settlement = new FabricaSettlement(address(seaport), address(morpho), address(this), initialPools);
        nft.mint(address(pool), TOKEN_ID);
        usdc.mint(payer, PRICE);
        usdc.mint(address(morpho), MAX_REPAYMENT);
        vm.prank(payer);
        usdc.approve(address(settlement), type(uint256).max);
        vm.prank(seller);
        nft.setApprovalForAll(address(seaport), true);
        vm.prank(seller);
        usdc.approve(address(settlement), MAX_REPAYMENT);
        receipt = _receipt();
    }

    function test_happyPath_relayerIsNotBuyer_andNoDust() public {
        AdvancedOrder memory order = _order(PRICE - FEE, false);
        vm.prank(payer);
        settlement.settleAndBuy(order, address(pool), receipt, buyer);
        assertEq(nft.balanceOf(buyer, TOKEN_ID), 1);
        assertEq(usdc.balanceOf(seller), PRICE - FEE - PAYOFF);
        assertEq(usdc.balanceOf(feeRecipient), FEE);
        assertEq(usdc.balanceOf(address(settlement)), 0);
        assertEq(usdc.balanceOf(payer), 0);
        assertEq(usdc.balanceOf(address(morpho)), MAX_REPAYMENT);
    }

    function test_happyPath_walletBuyer() public {
        usdc.mint(buyer, PRICE);
        vm.prank(buyer);
        usdc.approve(address(settlement), PRICE);

        vm.prank(buyer);
        settlement.settleAndBuy(_order(PRICE - FEE, false), address(pool), receipt, buyer);

        assertEq(nft.balanceOf(buyer, TOKEN_ID), 1);
        assertEq(usdc.balanceOf(buyer), 0);
        assertEq(usdc.balanceOf(seller), PRICE - FEE - PAYOFF);
    }

    function test_revert_constructorDependencyIsNotAContract() public {
        address eoa = makeAddr("zero-code dependency");
        address[] memory noPools = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(FabricaSettlement.NotAContract.selector, eoa));
        new FabricaSettlement(eoa, address(morpho), address(this), noPools);

        address[] memory invalidPools = new address[](1);
        invalidPools[0] = eoa;
        vm.expectRevert(abi.encodeWithSelector(FabricaSettlement.NotAContract.selector, eoa));
        new FabricaSettlement(address(seaport), address(morpho), address(this), invalidPools);
    }

    function test_donatedCurrencyDoesNotBlockSettlement() public {
        uint256 donation = 1;
        usdc.mint(address(settlement), donation);

        AdvancedOrder memory order = _order(PRICE - FEE, false);
        vm.prank(payer);
        settlement.settleAndBuy(order, address(pool), receipt, buyer);

        assertEq(nft.balanceOf(buyer, TOKEN_ID), 1);
        assertEq(usdc.balanceOf(seller), PRICE - FEE - PAYOFF);
        assertEq(usdc.balanceOf(feeRecipient), FEE);
        assertEq(usdc.balanceOf(address(settlement)), donation);
    }

    function test_revert_loanAlreadyRepaid() public {
        AdvancedOrder memory order = _order(PRICE - FEE, false);
        vm.prank(payer);
        settlement.settleAndBuy(order, address(pool), receipt, buyer);
        usdc.mint(payer, PRICE);
        vm.prank(payer);
        vm.expectRevert("inactive");
        settlement.settleAndBuy(order, address(pool), receipt, buyer);
    }

    function test_revert_underwaterAtExecution() public {
        SettlementTestPool underwater =
            new SettlementTestPool(IERC20(address(usdc)), nft, seller, TOKEN_ID, MAX_REPAYMENT + 1);
        settlement.setPoolAllowed(address(underwater), true);
        nft.mint(address(underwater), TOKEN_ID);
        vm.prank(payer);
        vm.expectRevert();
        settlement.settleAndBuy(_order(PRICE - FEE, false), address(underwater), receipt, buyer);
    }

    function test_revert_missingSellerAllowance() public {
        vm.prank(seller);
        usdc.approve(address(settlement), 0);
        vm.prank(payer);
        vm.expectRevert();
        settlement.settleAndBuy(_order(PRICE - FEE, false), address(pool), receipt, buyer);
    }

    function test_revert_borrowerNotARecipient() public {
        AdvancedOrder memory order = _order(PRICE - FEE, false);
        order.parameters.consideration[0].recipient = payable(makeAddr("wrong seller recipient"));

        vm.prank(payer);
        vm.expectRevert(FabricaSettlement.SellerRecipientMismatch.selector);
        settlement.settleAndBuy(order, address(pool), receipt, buyer);
    }

    function test_revert_unexpectedConsiderationTip() public {
        AdvancedOrder memory order = _order(PRICE - FEE, false);
        order.parameters.totalOriginalConsiderationItems = 1;

        vm.prank(payer);
        vm.expectRevert(FabricaSettlement.UnexpectedConsiderationTip.selector);
        settlement.settleAndBuy(order, address(pool), receipt, buyer);
    }

    function test_revert_expiredZoneExtraData() public {
        vm.prank(payer);
        vm.expectRevert("Oracle signature expired");
        settlement.settleAndBuy(_order(PRICE - FEE, true), address(pool), receipt, buyer);
    }

    function test_revert_directFlashCallback() public {
        vm.expectRevert(FabricaSettlement.UnauthorizedFlashCallback.selector);
        morpho.spoof(address(settlement), 1, "");
    }

    function test_revert_flashLoanRepayShortfall() public {
        morpho.setUnderpull(true);
        vm.prank(payer);
        vm.expectRevert();
        settlement.settleAndBuy(_order(PRICE - FEE, false), address(pool), receipt, buyer);
    }

    function test_revert_secondFlashCallback() public {
        morpho.setDoubleCallback(true);

        vm.prank(payer);
        vm.expectRevert(FabricaSettlement.UnauthorizedFlashCallback.selector);
        settlement.settleAndBuy(_order(PRICE - FEE, false), address(pool), receipt, buyer);
    }

    function test_revert_reentrancyAttempt() public {
        seaport.configureReentry(settlement);
        vm.prank(payer);
        vm.expectRevert();
        settlement.settleAndBuy(_order(PRICE - FEE, false), address(pool), receipt, buyer);
    }

    function test_revert_fakePoolAgainstLingeringSellerAllowance() public {
        vm.startPrank(seller);
        usdc.mint(seller, PAYOFF);
        usdc.approve(address(pool), PAYOFF);
        pool.repay(receipt);
        usdc.approve(address(settlement), MAX_REPAYMENT);
        vm.stopPrank();

        SettlementMaliciousPool maliciousPool = new SettlementMaliciousPool(IERC20(address(usdc)), PAYOFF);
        AdvancedOrder memory order = _order(PRICE - FEE, false);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(FabricaSettlement.PoolNotAllowed.selector, address(maliciousPool)));
        settlement.settleAndBuy(order, address(maliciousPool), receipt, buyer);
        assertEq(usdc.balanceOf(address(maliciousPool)), 0);
        assertEq(usdc.allowance(seller, address(settlement)), MAX_REPAYMENT);
    }

    function _order(uint256 sellerLeg, bool expired) internal view returns (AdvancedOrder memory order) {
        OfferItem[] memory offers = new OfferItem[](1);
        offers[0] = OfferItem(ItemType.ERC1155, address(nft), TOKEN_ID, 1, 1);
        ConsiderationItem[] memory legs = new ConsiderationItem[](2);
        legs[0] = ConsiderationItem(ItemType.ERC20, address(usdc), 0, sellerLeg, sellerLeg, payable(seller));
        legs[1] = ConsiderationItem(ItemType.ERC20, address(usdc), 0, FEE, FEE, payable(feeRecipient));
        OrderParameters memory parameters = OrderParameters({
            offerer: seller,
            zone: address(0),
            offer: offers,
            consideration: legs,
            orderType: OrderType.FULL_RESTRICTED,
            startTime: 0,
            endTime: type(uint256).max,
            zoneHash: bytes32(0),
            salt: 1,
            conduitKey: bytes32(0),
            totalOriginalConsiderationItems: 2
        });
        bytes memory extraData = expired ? bytes(hex"01") : bytes("");
        order = AdvancedOrder(parameters, 1, 1, "", extraData);
    }

    function _receipt() internal view returns (bytes memory) {
        return abi.encodePacked(
            uint8(2),
            uint256(1),
            MAX_REPAYMENT * 1e12,
            uint256(0),
            seller,
            uint64(block.timestamp + 1 days),
            uint64(1 days),
            address(nft),
            TOKEN_ID,
            uint16(0)
        );
    }
}
