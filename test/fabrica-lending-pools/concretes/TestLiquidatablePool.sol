// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../../../src/fabrica-lending-pools/Pool.sol";
import "../../../src/fabrica-lending-pools/tokenization/ERC20DepositToken.sol";

/**
 * @title Concrete Pool that exercises the borrow → default → liquidate path
 * for the Fabrica ENG-3113 liquidation grace-period guard.
 *
 * Extends the borrow/repay-capable stub (mirrors TestRepayablePool) but takes
 * a real collateral liquidator and a configurable grace period in the
 * constructor so tests can drive Pool.liquidate() end-to-end. Trivial interest
 * model keeps repayment == principal; the ERC721 base collateral path is used.
 */
contract TestLiquidatablePool is Pool, ERC20DepositToken {
    constructor(address erc20DepositTokenImpl, address collateralLiquidator, uint64 liquidationGracePeriod_)
        Pool(collateralLiquidator, address(0), address(0), new address[](0), liquidationGracePeriod_)
        ERC20DepositToken(erc20DepositTokenImpl)
    {}

    function initialize(address currencyToken_, uint64[] memory durations_, uint64[] memory rates_) external {
        Pool._initialize(currencyToken_, durations_, rates_);
    }

    function IMPLEMENTATION_NAME() external pure override returns (string memory) {
        return "TestLiquidatablePool";
    }

    function COLLATERAL_FILTER_NAME() external pure override returns (string memory) {
        return "TestPermissiveCollateralFilter";
    }

    function COLLATERAL_FILTER_VERSION() external pure override returns (string memory) {
        return "0.0.0";
    }

    function collateralToken() public pure override returns (address) {
        return address(0);
    }

    function collateralTokens() external pure override returns (address[] memory) {
        return new address[](0);
    }

    function _collateralSupported(address, uint256, uint256, bytes calldata) internal pure override returns (bool) {
        return true;
    }

    function INTEREST_RATE_MODEL_NAME() external pure override returns (string memory) {
        return "TestTrivialInterestRateModel";
    }

    function INTEREST_RATE_MODEL_VERSION() external pure override returns (string memory) {
        return "0.0.0";
    }

    function _price(
        uint256 principal,
        uint64,
        LiquidityLogic.NodeSource[] memory nodes,
        uint16 count,
        uint64[] memory,
        uint32
    ) internal pure override returns (uint256 repayment, uint256 adminFee) {
        /* No interest — repayment equals principal. Set each node's pending
           to its used so LiquidityLogic.use() doesn't underflow on
           `pending - used`. */
        for (uint256 i; i < count; i++) {
            nodes[i].pending = nodes[i].used;
        }
        return (principal, 0);
    }

    function price(address, address, uint256[] memory, uint256[] memory, bytes calldata)
        public
        pure
        override
        returns (uint256)
    {
        return 0;
    }
}
