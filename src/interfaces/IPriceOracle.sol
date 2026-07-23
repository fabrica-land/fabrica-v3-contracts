// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal lending-pool price oracle interface.
/// @dev Matches the external MetaStreet pool oracle ABI consumed by pool quote paths.
interface IPriceOracle {
    function price(
        address collateralToken,
        address currencyToken,
        uint256[] memory collateralTokenIds,
        uint256[] memory collateralTokenQuantities,
        bytes calldata oracleContext
    ) external view returns (uint256);
}
