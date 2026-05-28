// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../../../src/fabrica-lending-pools/interfaces/ICollateralLiquidator.sol";

/**
 * @title No-op collateral liquidator for grace-period tests (Fabrica ENG-3113).
 *
 * Pool.liquidate() approves this contract for the collateral and then calls
 * liquidate(). The grace-period guard under test lives entirely in
 * Pool.liquidate() before this hand-off, so the liquidator itself need only
 * accept the call without reverting — it does not need to run an auction.
 * Collateral is left escrowed in the pool (approved to this mock); the tests
 * assert on the loan-status transition, not on auction proceeds.
 */
contract MockCollateralLiquidator is ICollateralLiquidator {
    function name() external pure returns (string memory) {
        return "MockCollateralLiquidator";
    }

    function liquidate(address, address, uint256, bytes calldata, bytes calldata) external {}
}
