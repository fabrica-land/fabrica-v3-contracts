// SPDX-License-Identifier: BUSL-1.1
// Vendored from metastreet-labs/metastreet-contracts-v2 @ 8ed467d272a2cee35751e60851fa1b830e2fe018
// Modifications: see git history of this file in fabrica-land/fabrica-v3-contracts.
pragma solidity 0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "./Pool.sol";
import "./Tick.sol";
import "./LiquidityLogic.sol";

import "./interfaces/IPool.sol";

/**
 * @dev Minimal view of the ERC20 deposit token's transfer hook. Declared
 * locally so this library makes the one external call it needs without
 * importing the full ERC20DepositTokenImplementation concrete (which would
 * create a Pool -> DepositLogic -> ERC20DepositTokenImplementation -> Pool
 * import cycle). Signature must match
 * ERC20DepositTokenImplementation.onExternalTransfer.
 */
interface IDepositTokenHook {
    function onExternalTransfer(address from, address to, uint256 value) external;
}

/**
 * @title Deposit Logic
 * @author MetaStreet Labs
 */
library DepositLogic {
    using LiquidityLogic for LiquidityLogic.Liquidity;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /**************************************************************************/
    /* Fabrica ENG-3231: LP-dispatch orchestration moved off the Pool concrete
       to reclaim EIP-170 runtime-bytecode budget for the breaking borrow()
       borrower parameter. These external functions are delegatecalled by the
       thin Pool stubs (deposit/depositFor/redeem/withdraw/rebalance/transfer),
       so currency-token transfers, scaling, the deposit-token transfer hook,
       and event emission all execute in the Pool's storage/context (address(this)
       == Pool, msg.sender == the original caller). The hook target deposit-token
       address is resolved here by reading the deposit-token ERC-7201 storage slot
       directly (a byte-for-byte mirror of ERC20DepositToken's layout), which
       avoids a round-trip call back into the Pool concrete. */
    /**************************************************************************/

    /**
     * @dev ERC-7201 deposit-token storage (mirror of ERC20DepositToken's layout
     * so this library can resolve a tick's deposit-token address in the Pool's
     * delegatecall context without an extra call back into the Pool concrete).
     * @custom:storage-location erc7201:erc20DepositToken.depositTokenStorage
     */
    struct DepositTokenStorage {
        mapping(uint128 => address) tokens;
    }

    /**
     * @dev Deposit-token storage slot
     * keccak256(abi.encode(uint256(keccak256("erc20DepositToken.depositTokenStorage")) - 1)) & ~bytes32(uint256(0xff));
     * Must match ERC20DepositToken.DEPOSIT_TOKEN_STORAGE_LOCATION exactly.
     */
    bytes32 private constant DEPOSIT_TOKEN_STORAGE_LOCATION =
        0xc61d9ab4916a5eab6b572dc8707662b99e55e17ecdc61af8ff79465ad64ded00;

    /**
     * @dev Get reference to ERC-7201 deposit token storage
     * @return $ Reference to deposit token storage
     */
    function _getDepositTokenStorage() private pure returns (DepositTokenStorage storage $) {
        assembly {
            $.slot := DEPOSIT_TOKEN_STORAGE_LOCATION
        }
    }

    /**
     * @dev Resolve the deposit-token address for a tick (address(0) if untokenized)
     * @param tick Tick
     * @return Deposit-token address
     */
    function _depositToken(uint128 tick) private view returns (address) {
        return _getDepositTokenStorage().tokens[tick];
    }

    /**
     * @dev Currency-token scaling factor (mirror of Pool._scaleFactor)
     * @param self Pool storage
     * @return Factor
     */
    function _scaleFactor(Pool.PoolStorage storage self) private view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(address(self.currencyToken)).decimals());
    }

    /**
     * @dev Scale a currency-token amount up to internal 18-decimal fixed point
     * @param self Pool storage
     * @param value Value
     * @return Scaled value
     */
    function _scale(Pool.PoolStorage storage self, uint256 value) private view returns (uint256) {
        return value * _scaleFactor(self);
    }

    /**
     * @dev Scale an internal 18-decimal value down to currency-token units
     * @param self Pool storage
     * @param value Value
     * @param isRoundUp Round up if true
     * @return Unscaled value
     */
    function _unscale(Pool.PoolStorage storage self, uint256 value, bool isRoundUp) private view returns (uint256) {
        uint256 factor = _scaleFactor(self);
        return (value % factor == 0 || !isRoundUp) ? value / factor : value / factor + 1;
    }

    /**
     * @dev Deposit currency into a tick and credit shares to a recipient
     * @param self Pool storage
     * @param recipient Address to credit deposit shares to
     * @param tick Tick
     * @param amount Currency token amount
     * @param minShares Minimum shares
     * @return Deposit shares
     */
    function depositFor(
        Pool.PoolStorage storage self,
        address recipient,
        uint128 tick,
        uint256 amount,
        uint256 minShares
    ) external returns (uint256) {
        /* Validate recipient */
        if (recipient == address(0)) revert IPool.InvalidRecipient();
        /* Handle deposit accounting and credit shares to recipient */
        uint128 shares = _deposit(self, tick, _scale(self, amount).toUint128(), minShares.toUint128(), recipient);
        /* Call token hook (mints wrapper Transfer event from address(0) to recipient) */
        address depositTokenInstance = _depositToken(tick);
        if (depositTokenInstance != address(0))
            IDepositTokenHook(depositTokenInstance).onExternalTransfer(address(0), recipient, shares);
        /* Transfer deposit amount from msg.sender (payer) */
        self.currencyToken.safeTransferFrom(msg.sender, address(this), amount);
        /* Emit Deposited keyed on recipient */
        emit IPool.Deposited(recipient, tick, amount, shares);
        return shares;
    }

    /**
     * @dev Redeem shares from a tick
     * @param self Pool storage
     * @param tick Tick
     * @param shares Shares
     * @return Redemption ID
     */
    function redeem(Pool.PoolStorage storage self, uint128 tick, uint256 shares) external returns (uint128) {
        /* Handle redeem accounting */
        uint128 redemptionId = _redeem(self, tick, shares.toUint128());
        /* Call token hook */
        address depositTokenInstance = _depositToken(tick);
        if (depositTokenInstance != address(0))
            IDepositTokenHook(depositTokenInstance).onExternalTransfer(msg.sender, address(0), shares);
        /* Emit Redeemed event */
        emit IPool.Redeemed(msg.sender, tick, redemptionId, shares);
        return redemptionId;
    }

    /**
     * @dev Withdraw a processed redemption
     * @param self Pool storage
     * @param tick Tick
     * @param redemptionId Redemption ID
     * @return Withdrawn shares and unscaled withdrawn amount
     */
    function withdraw(
        Pool.PoolStorage storage self,
        uint128 tick,
        uint128 redemptionId
    ) external returns (uint256, uint256) {
        /* Handle withdraw accounting and compute both shares and amount */
        (uint128 shares, uint128 amount) = _withdraw(self, tick, redemptionId);
        uint256 unscaledAmount = _unscale(self, amount, false);
        /* Transfer withdrawal amount */
        if (unscaledAmount != 0) self.currencyToken.safeTransfer(msg.sender, unscaledAmount);
        /* Emit Withdrawn */
        emit IPool.Withdrawn(msg.sender, tick, redemptionId, shares, unscaledAmount);
        return (shares, unscaledAmount);
    }

    /**
     * @dev Rebalance a processed redemption into a new tick
     * @param self Pool storage
     * @param srcTick Source tick
     * @param dstTick Destination tick
     * @param redemptionId Redemption ID
     * @param minShares Minimum shares
     * @return Old shares, new shares, unscaled amount
     */
    function rebalance(
        Pool.PoolStorage storage self,
        uint128 srcTick,
        uint128 dstTick,
        uint128 redemptionId,
        uint256 minShares
    ) external returns (uint256, uint256, uint256) {
        /* Handle withdraw accounting and compute both shares and amount */
        (uint128 oldShares, uint128 amount) = _withdraw(self, srcTick, redemptionId);
        /* Handle deposit accounting and compute new shares (rebalance keeps msg.sender as beneficiary) */
        uint128 newShares = _deposit(self, dstTick, amount, minShares.toUint128(), msg.sender);
        uint256 unscaledAmount = _unscale(self, amount, false);
        /* Call token hook */
        address dstDepositTokenInstance = _depositToken(dstTick);
        if (dstDepositTokenInstance != address(0))
            IDepositTokenHook(dstDepositTokenInstance).onExternalTransfer(address(0), msg.sender, newShares);
        /* Emit Withdrawn */
        emit IPool.Withdrawn(msg.sender, srcTick, redemptionId, oldShares, unscaledAmount);
        /* Emit Deposited */
        emit IPool.Deposited(msg.sender, dstTick, unscaledAmount, newShares);
        return (oldShares, newShares, unscaledAmount);
    }

    /**
     * @dev Transfer shares between accounts by the tick's deposit token
     * @param self Pool storage
     * @param from From
     * @param to To
     * @param tick Tick
     * @param shares Shares
     */
    function transfer(
        Pool.PoolStorage storage self,
        address from,
        address to,
        uint128 tick,
        uint256 shares
    ) external {
        /* Validate caller is deposit token created by Pool */
        if (msg.sender != _depositToken(tick)) revert IPool.InvalidCaller();
        /* Handle transfer accounting */
        _transfer(self, from, to, tick, shares.toUint128());
        /* Emit Transferred */
        emit IPool.Transferred(from, to, tick, shares);
    }

    /**
     * @dev Helper function to handle deposit accounting
     * @param self Pool storage
     * @param tick Tick
     * @param amount Amount
     * @param minShares Minimum shares
     * @param beneficiary Address to credit deposit shares to
     * @return Deposit shares
     */
    function _deposit(
        Pool.PoolStorage storage self,
        uint128 tick,
        uint128 amount,
        uint128 minShares,
        address beneficiary
    ) internal returns (uint128) {
        /* Validate tick */
        Tick.validate(tick, 0, 0, self.durations.length - 1, 0, self.rates.length - 1);

        /* Deposit into liquidity node */
        uint128 shares = self.liquidity.deposit(tick, amount);

        /* Validate shares received is sufficient */
        if (shares == 0 || shares < minShares) revert IPool.InsufficientShares();

        /* Add to deposit */
        self.deposits[beneficiary][tick].shares += shares;

        return shares;
    }

    /**
     * @dev Helper function to handle redeem accounting
     * @param self Pool storage
     * @param tick Tick
     * @param shares Shares
     * @return redemptionId Redemption ID
     */
    function _redeem(Pool.PoolStorage storage self, uint128 tick, uint128 shares) internal returns (uint128) {
        /* Look up deposit */
        Pool.Deposit storage dep = self.deposits[msg.sender][tick];

        /* Assign redemption ID */
        uint128 redemptionId = dep.redemptionId++;

        /* Look up redemption */
        Pool.Redemption storage redemption = dep.redemptions[redemptionId];

        /* Validate shares */
        if (shares == 0 || shares > dep.shares) revert IPool.InsufficientShares();

        /* Redeem shares in tick with liquidity manager */
        (uint128 index, uint128 target) = self.liquidity.redeem(tick, shares);

        /* Update deposit state */
        redemption.pending = shares;
        redemption.index = index;
        redemption.target = target;

        /* Decrement deposit shares */
        dep.shares -= shares;

        return redemptionId;
    }

    /**
     * @dev Helper function to handle withdraw accounting
     * @param self Pool storage
     * @param tick Tick
     * @param redemptionId Redemption ID
     * @return Withdrawn shares and withdrawn amount
     */
    function _withdraw(
        Pool.PoolStorage storage self,
        uint128 tick,
        uint128 redemptionId
    ) internal returns (uint128, uint128) {
        /* Look up redemption */
        Pool.Redemption storage redemption = self.deposits[msg.sender][tick].redemptions[redemptionId];

        /* If no redemption is pending */
        if (redemption.pending == 0) revert IPool.InvalidRedemptionStatus();

        /* Look up redemption available */
        (uint128 shares, uint128 amount, uint128 processedIndices, uint128 processedShares) = self
            .liquidity
            .redemptionAvailable(tick, redemption.pending, redemption.index, redemption.target);

        /* If the entire redemption is ready */
        if (shares == redemption.pending) {
            delete self.deposits[msg.sender][tick].redemptions[redemptionId];
        } else {
            redemption.pending -= shares;
            redemption.index += processedIndices;
            redemption.target = (processedShares < redemption.target) ? redemption.target - processedShares : 0;
        }

        return (shares, amount);
    }

    /**
     * @dev Helper function to handle transfer accounting
     * @param self Pool storage
     * @param from From
     * @param to To
     * @param tick Tick
     * @param shares Shares
     */
    function _transfer(Pool.PoolStorage storage self, address from, address to, uint128 tick, uint128 shares) internal {
        if (self.deposits[from][tick].shares < shares) revert IPool.InsufficientShares();

        self.deposits[from][tick].shares -= shares;
        self.deposits[to][tick].shares += shares;
    }

    /**
     * Helper function to look up redemption available
     * @param self Pool storage
     * @param account Account
     * @param tick Tick
     * @param redemptionId Redemption ID
     * @return shares Amount of deposit shares available for redemption
     * @return amount Amount of currency tokens available for withdrawal
     * @return sharesAhead Amount of pending shares ahead in queue
     */
    function _redemptionAvailable(
        Pool.PoolStorage storage self,
        address account,
        uint128 tick,
        uint128 redemptionId
    ) external view returns (uint256 shares, uint256 amount, uint256 sharesAhead) {
        /* Look up redemption */
        Pool.Redemption storage redemption = self.deposits[account][tick].redemptions[redemptionId];

        /* If no redemption is pending */
        if (redemption.pending == 0) return (0, 0, 0);

        uint128 processedShares;
        (shares, amount, , processedShares) = self.liquidity.redemptionAvailable(
            tick,
            redemption.pending,
            redemption.index,
            redemption.target
        );

        /* Compute pending shares ahead in queue */
        sharesAhead = redemption.target > processedShares ? redemption.target - processedShares : 0;
    }
}
