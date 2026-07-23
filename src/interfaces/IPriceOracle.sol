// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal lending-pool price oracle interface.
/// @dev Matches the external MetaStreet pool oracle ABI consumed by pool quote paths.
interface IPriceOracle {
    /// @notice Return the aggregate oracle price for a collateral basket.
    /// @param collateralToken Collateral contract being valued.
    /// @param currencyToken Currency contract used for the returned price.
    /// @param collateralTokenIds Collateral token IDs being valued.
    /// @param collateralTokenQuantities Quantity for each collateral token ID.
    /// @param oracleContext ABI-encoded oracle-specific quote data.
    /// @return aggregatePrice Quantity-weighted price used by the lending pool.
    function price(
        address collateralToken,
        address currencyToken,
        uint256[] memory collateralTokenIds,
        uint256[] memory collateralTokenQuantities,
        bytes calldata oracleContext
    ) external view returns (uint256);
}
