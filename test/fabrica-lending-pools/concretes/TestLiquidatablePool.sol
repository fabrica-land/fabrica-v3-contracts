// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./TestPermissivePoolBase.sol";

/**
 * @title Concrete permissive pool for the borrow → default → liquidate path,
 * for the Fabrica ENG-3113 liquidation grace-period guard.
 *
 * Adds a real collateral liquidator and a configurable grace period to the
 * shared TestPermissivePoolBase stubs so tests can drive Pool.liquidate()
 * end-to-end against a constructor-set grace window.
 */
contract TestLiquidatablePool is TestPermissivePoolBase {
    constructor(address erc20DepositTokenImpl, address collateralLiquidator, uint64 liquidationGracePeriod_)
        Pool(collateralLiquidator, address(0), address(0), new address[](0), liquidationGracePeriod_)
        ERC20DepositToken(erc20DepositTokenImpl)
    {}

    function IMPLEMENTATION_NAME() external pure override returns (string memory) {
        return "TestLiquidatablePool";
    }
}
