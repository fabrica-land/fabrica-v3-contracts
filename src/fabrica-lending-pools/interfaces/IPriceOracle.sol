// SPDX-License-Identifier: MIT
// Vendored from metastreet-labs/metastreet-contracts-v2 @ 8ed467d272a2cee35751e60851fa1b830e2fe018
// Modifications: see git history of this file in fabrica-land/fabrica-v3-contracts.
pragma solidity ^0.8.0;

/**
 * @title Interface to a Price Oracle
 */
interface IPriceOracle {
    /**
     * @notice Fetch price of token IDs
     * @param collateralToken Pool collateral token
     * @param currencyToken Pool currency token
     * @param tokenIds Token IDs
     * @param tokenIdQuantities Token ID quantities
     * @param oracleContext Oracle context
     * @return price Token price in the same decimals as currency token
     */
    function price(
        address collateralToken,
        address currencyToken,
        uint256[] memory tokenIds,
        uint256[] memory tokenIdQuantities,
        bytes calldata oracleContext
    ) external view returns (uint256 price);
}
