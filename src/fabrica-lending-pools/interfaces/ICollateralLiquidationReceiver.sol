// SPDX-License-Identifier: MIT
// Vendored from metastreet-labs/metastreet-contracts-v2 @ 8ed467d272a2cee35751e60851fa1b830e2fe018
// Modifications: see git history of this file in fabrica-land/fabrica-v3-contracts.
pragma solidity ^0.8.0;

/**
 * @title Interface to a Collateral Liquidation Receiver
 */
interface ICollateralLiquidationReceiver {
    /**
     * @notice Callback on collateral liquidated
     * @dev Pre-conditions: 1) proceeds were transferred, and 2) transferred amount >= proceeds
     * @param liquidationContext Liquidation context
     * @param proceeds Liquidation proceeds in currency tokens
     */
    function onCollateralLiquidated(bytes calldata liquidationContext, uint256 proceeds) external;
}
