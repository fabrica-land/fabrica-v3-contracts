// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ConsiderationInterface} from "seaport-types/interfaces/ConsiderationInterface.sol";
import {AdvancedOrder, CriteriaResolver, OrderComponents} from "seaport-types/lib/ConsiderationStructs.sol";
import {ItemType} from "seaport-types/lib/ConsiderationEnums.sol";
import {ISettlementPool} from "./interfaces/ISettlementPool.sol";
import {ISettlementMorpho, ISettlementMorphoFlashLoanCallback} from "./interfaces/ISettlementMorpho.sol";
import {SettlementLoanReceipt} from "./libraries/SettlementLoanReceipt.sol";

/// @notice Atomically repays a MetaStreet v2 loan and fills its collateral's Seaport listing.
contract FabricaSettlement is
    Ownable2Step,
    Pausable,
    ReentrancyGuard,
    ERC1155Holder,
    ISettlementMorphoFlashLoanCallback
{
    using SafeERC20 for IERC20;

    error InvalidAddress();
    error InvalidOrder();
    error InvalidConsideration();
    error ReceiptOrderMismatch();
    error PriceBelowConsideration(uint256 price, uint256 consideration);
    error PriceBelowHeadroom(uint256 price, uint256 required);
    error PoolNotAllowed(address pool);
    error UnexpectedClawback(uint256 payoff, uint256 headroom);
    error SellerRecipientMismatch();
    error UnexpectedConsiderationTip();
    error SeaportFulfillmentFailed();
    error UnauthorizedFlashCallback();
    error FlashAmountMismatch(uint256 actual, uint256 expected);
    error UnsupportedCurrencyDecimals(address currency, uint8 decimals);
    error SettlementBalanceNotZero(uint256 balance);

    /// @notice Selects whether the payoff is prepaid in the purchase price or clawed back from sale proceeds.
    /// @dev `PriceHeadroom` never pulls from the seller. `SellerAllowance` may pull a shortfall from the borrower.
    enum PayoffFunding {
        PriceHeadroom,
        SellerAllowance
    }

    event PoolAllowedSet(address indexed pool, bool allowed);

    /// @notice Emitted after the loan payoff and Seaport purchase complete atomically.
    /// @param orderHash Seaport hash of the original, tip-free order.
    /// @param tokenId Fabrica collateral token ID purchased by the buyer.
    /// @param buyer Recipient of the collateral; this may differ from the permissionless caller.
    /// @param seller Borrower whose loan was repaid and whose order was filled.
    /// @param pool Allowlisted lending pool repaid by the settlement.
    /// @param price Amount funded by the caller.
    /// @param payoffPaid Actual currency amount consumed by the pool repayment.
    /// @param sellerClawback Amount pulled from the seller in `SellerAllowance` mode.
    event SettlementExecuted(
        bytes32 indexed orderHash,
        uint256 indexed tokenId,
        address indexed buyer,
        address seller,
        address pool,
        uint256 price,
        uint256 payoffPaid,
        uint256 sellerClawback
    );

    ConsiderationInterface public immutable seaport;
    ISettlementMorpho public immutable morpho;
    mapping(address => bool) public allowedPools;

    bool private _settlementInFlight;
    bytes32 private _callbackHash;

    struct SettlementData {
        AdvancedOrder order;
        address pool;
        bytes encodedLoanReceipt;
        address buyer;
        uint256 price;
        PayoffFunding payoffFunding;
        uint256 legsTotal;
        uint256 maxRepayment;
        SettlementLoanReceipt.Details receipt;
        address currency;
    }

    /// @notice Deploys settlement against Seaport, Morpho, and an initial pool allowlist.
    /// @param seaport_ Seaport 1.6 consideration contract.
    /// @param morpho_ Morpho-compatible zero-fee flash-loan provider.
    /// @param owner_ Owner authorized to pause, rescue assets, and manage pools.
    /// @param initialPools Lending pools permitted at deployment.
    constructor(address seaport_, address morpho_, address owner_, address[] memory initialPools) Ownable(owner_) {
        if (seaport_ == address(0) || morpho_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        seaport = ConsiderationInterface(seaport_);
        morpho = ISettlementMorpho(morpho_);
        for (uint256 i; i < initialPools.length; ++i) {
            if (initialPools[i] == address(0)) revert InvalidAddress();
            allowedPools[initialPools[i]] = true;
            emit PoolAllowedSet(initialPools[i], true);
        }
    }

    /// @notice Atomically repays a loan and buys its released collateral through Seaport.
    /// @dev Calling is permissionless. Currency is pulled from `msg.sender`, while collateral is sent to `buyer`.
    /// @param order Signed Seaport order with static ERC-20 consideration and no appended tips.
    /// @param pool Allowlisted pool holding the collateral.
    /// @param encodedLoanReceipt Pool-specific encoded receipt describing the loan.
    /// @param buyer Collateral recipient, which need not be `msg.sender`.
    /// @param price Currency amount supplied by `msg.sender`.
    /// @param payoffFunding Funding mode: price headroom or seller allowance clawback.
    function settleAndBuy(
        AdvancedOrder calldata order,
        address pool,
        bytes calldata encodedLoanReceipt,
        address buyer,
        uint256 price,
        PayoffFunding payoffFunding
    ) external nonReentrant whenNotPaused {
        if (pool == address(0) || buyer == address(0)) revert InvalidAddress();
        if (!allowedPools[pool]) revert PoolNotAllowed(pool);

        SettlementLoanReceipt.Details memory receipt = SettlementLoanReceipt.decode(encodedLoanReceipt);
        (IERC20 currency, uint256 legsTotal, uint256 maxRepayment) = _validate(order, receipt, pool, payoffFunding);
        uint256 balanceBefore = currency.balanceOf(address(this));
        if (legsTotal > price) revert PriceBelowConsideration(price, legsTotal);
        if (maxRepayment > type(uint256).max - legsTotal) revert InvalidConsideration();
        if (payoffFunding == PayoffFunding.PriceHeadroom && price < legsTotal + maxRepayment) {
            revert PriceBelowHeadroom(price, legsTotal + maxRepayment);
        }
        currency.safeTransferFrom(msg.sender, address(this), price);

        uint256 flashAmount = legsTotal + maxRepayment > price ? legsTotal + maxRepayment - price : 0;
        SettlementData memory settlementData = SettlementData({
            order: order,
            pool: pool,
            encodedLoanReceipt: encodedLoanReceipt,
            buyer: buyer,
            price: price,
            payoffFunding: payoffFunding,
            legsTotal: legsTotal,
            maxRepayment: maxRepayment,
            receipt: receipt,
            currency: address(currency)
        });
        if (flashAmount == 0) {
            _execute(settlementData);
        } else {
            bytes memory data = abi.encode(settlementData);
            _settlementInFlight = true;
            _callbackHash = keccak256(data);
            morpho.flashLoan(address(currency), flashAmount, data);
            _settlementInFlight = false;
            _callbackHash = bytes32(0);
        }

        uint256 balance = currency.balanceOf(address(this));
        if (balance != balanceBefore) revert SettlementBalanceNotZero(balance);
    }

    /// @notice Executes settlement during the authenticated Morpho flash-loan callback.
    /// @param assets Flash principal supplied by Morpho.
    /// @param data Encoded settlement state committed before requesting the flash loan.
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho) || !_settlementInFlight || keccak256(data) != _callbackHash) {
            revert UnauthorizedFlashCallback();
        }
        SettlementData memory settlementData = abi.decode(data, (SettlementData));
        _settlementInFlight = false;
        _callbackHash = bytes32(0);
        uint256 expected = settlementData.legsTotal + settlementData.maxRepayment - settlementData.price;
        if (assets != expected) revert FlashAmountMismatch(assets, expected);

        _execute(settlementData);
        IERC20 currency = IERC20(settlementData.currency);
        currency.forceApprove(address(morpho), assets);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Adds or removes a lending pool from the settlement allowlist.
    /// @param pool Pool whose status is updated.
    /// @param allowed Whether settlement may repay the pool.
    function setPoolAllowed(address pool, bool allowed) external onlyOwner {
        allowedPools[pool] = allowed;
        emit PoolAllowedSet(pool, allowed);
    }

    /// @notice Rescues ERC-20 assets accidentally sent to this contract.
    /// @param token ERC-20 token to transfer.
    /// @param recipient Address receiving the rescued tokens.
    /// @param amount Amount to rescue.
    function rescueERC20(address token, address recipient, uint256 amount) external onlyOwner {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(recipient, amount);
    }

    /// @notice Rescues ERC-1155 assets accidentally sent to this contract.
    /// @param token ERC-1155 token contract.
    /// @param recipient Address receiving the rescued tokens.
    /// @param id Token ID to rescue.
    /// @param amount Token amount to rescue.
    /// @param data ERC-1155 receiver callback data.
    function rescueERC1155(address token, address recipient, uint256 id, uint256 amount, bytes calldata data)
        external
        onlyOwner
    {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        IERC1155(token).safeTransferFrom(address(this), recipient, id, amount, data);
    }

    function _validate(
        AdvancedOrder calldata order,
        SettlementLoanReceipt.Details memory receipt,
        address pool,
        PayoffFunding payoffFunding
    ) private view returns (IERC20 currency, uint256 legsTotal, uint256 maxRepayment) {
        if (
            order.numerator == 0 || order.numerator != order.denominator || order.parameters.offer.length != 1
                || order.parameters.conduitKey != bytes32(0)
        ) revert InvalidOrder();

        if (
            order.parameters.offerer != receipt.borrower || order.parameters.offer[0].itemType != ItemType.ERC1155
                || order.parameters.offer[0].token != receipt.collateralToken
                || order.parameters.offer[0].identifierOrCriteria != receipt.collateralTokenId
                || order.parameters.offer[0].startAmount != 1 || order.parameters.offer[0].endAmount != 1
        ) revert ReceiptOrderMismatch();

        address currencyAddress = ISettlementPool(pool).currencyToken();
        if (currencyAddress == address(0)) revert InvalidAddress();
        currency = IERC20(currencyAddress);
        uint8 decimals = IERC20Metadata(currencyAddress).decimals();
        if (decimals > 18) revert UnsupportedCurrencyDecimals(currencyAddress, decimals);
        uint256 factor = 10 ** (18 - decimals);
        maxRepayment = receipt.maxRepayment / factor;
        if (receipt.maxRepayment % factor != 0) ++maxRepayment;

        uint256 length = order.parameters.consideration.length;
        if (length == 0) revert InvalidConsideration();
        if (order.parameters.totalOriginalConsiderationItems != length) revert UnexpectedConsiderationTip();
        bool hasSellerProceedsLeg;
        for (uint256 i; i < length; ++i) {
            if (
                order.parameters.consideration[i].itemType != ItemType.ERC20
                    || order.parameters.consideration[i].token != currencyAddress
                    || order.parameters.consideration[i].identifierOrCriteria != 0
                    || order.parameters.consideration[i].startAmount != order.parameters.consideration[i].endAmount
            ) revert InvalidConsideration();
            legsTotal += order.parameters.consideration[i].startAmount;
            if (order.parameters.consideration[i].recipient == receipt.borrower) hasSellerProceedsLeg = true;
        }
        if (payoffFunding == PayoffFunding.SellerAllowance && !hasSellerProceedsLeg) {
            revert SellerRecipientMismatch();
        }
    }

    function _execute(SettlementData memory settlementData) private {
        IERC20 currency = IERC20(settlementData.currency);
        bytes32 orderHash = _orderHash(settlementData.order);
        uint256 beforeRepay = currency.balanceOf(address(this));
        currency.forceApprove(settlementData.pool, settlementData.maxRepayment);
        ISettlementPool(settlementData.pool).repay(settlementData.encodedLoanReceipt);
        uint256 payoff = beforeRepay - currency.balanceOf(address(this));
        currency.forceApprove(settlementData.pool, 0);

        currency.forceApprove(address(seaport), settlementData.legsTotal);
        CriteriaResolver[] memory resolvers = new CriteriaResolver[](0);
        if (!seaport.fulfillAdvancedOrder(settlementData.order, resolvers, bytes32(0), settlementData.buyer)) {
            revert SeaportFulfillmentFailed();
        }
        currency.forceApprove(address(seaport), 0);

        uint256 headroom = settlementData.price - settlementData.legsTotal;
        uint256 sellerClawback;
        if (payoff > headroom) {
            if (settlementData.payoffFunding == PayoffFunding.PriceHeadroom) {
                revert UnexpectedClawback(payoff, headroom);
            }
            sellerClawback = payoff - headroom;
            currency.safeTransferFrom(settlementData.receipt.borrower, address(this), sellerClawback);
        } else if (headroom > payoff) {
            currency.safeTransfer(settlementData.receipt.borrower, headroom - payoff);
        }

        emit SettlementExecuted(
            orderHash,
            settlementData.receipt.collateralTokenId,
            settlementData.buyer,
            settlementData.receipt.borrower,
            settlementData.pool,
            settlementData.price,
            payoff,
            sellerClawback
        );
    }

    function _orderHash(AdvancedOrder memory order) private view returns (bytes32) {
        OrderComponents memory components = OrderComponents({
            offerer: order.parameters.offerer,
            zone: order.parameters.zone,
            offer: order.parameters.offer,
            consideration: order.parameters.consideration,
            orderType: order.parameters.orderType,
            startTime: order.parameters.startTime,
            endTime: order.parameters.endTime,
            zoneHash: order.parameters.zoneHash,
            salt: order.parameters.salt,
            conduitKey: order.parameters.conduitKey,
            counter: seaport.getCounter(order.parameters.offerer)
        });
        return seaport.getOrderHash(components);
    }
}
