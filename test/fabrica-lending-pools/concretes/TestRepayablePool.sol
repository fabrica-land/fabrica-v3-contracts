// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "./TestPermissivePoolBase.sol";

/**
 * @title Concrete permissive pool for the borrow → repay path (ENG-3076).
 *
 * No collateral liquidator and no grace period — the repay tests never call
 * liquidate(). All stub behavior lives in TestPermissivePoolBase.
 */
contract TestRepayablePool is TestPermissivePoolBase {
    constructor(address erc20DepositTokenImpl)
        Pool(address(0), address(0), address(0), new address[](0), 0)
        ERC20DepositToken(erc20DepositTokenImpl)
    {}

    function IMPLEMENTATION_NAME() external pure override returns (string memory) {
        return "TestRepayablePool";
    }
}
