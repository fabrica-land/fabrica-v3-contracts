// SPDX-License-Identifier: MIT
// Vendored from metastreet-labs/metastreet-contracts-v2 @ 8ed467d272a2cee35751e60851fa1b830e2fe018
// Modifications: see git history of this file in fabrica-land/fabrica-v3-contracts.
pragma solidity ^0.8.0;

/**
 * @title Interface to a Collateral Liquidator
 */
interface ICollateralLiquidator {
    /**
     * @notice Get collateral liquidator name
     * @return Collateral liquidator name
     */
    function name() external view returns (string memory);

    /**
     * @notice Liquidate collateral
     * @param currencyToken Currency token
     * @param collateralToken Collateral token, either underlying token or collateral wrapper
     * @param collateralTokenId Collateral token ID
     * @param collateralWrapperContext Collateral wrapper context
     * @param liquidationContext Liquidation callback context
     */
    function liquidate(
        address currencyToken,
        address collateralToken,
        uint256 collateralTokenId,
        bytes calldata collateralWrapperContext,
        bytes calldata liquidationContext
    ) external;
}
