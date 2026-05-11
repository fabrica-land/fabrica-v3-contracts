// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../../src/fabrica-lending-pools/Pool.sol";
import "../../../src/fabrica-lending-pools/tokenization/ERC20DepositToken.sol";

/**
 * @title Minimal concrete Pool for unit testing the deposit / depositFor
 * accounting and event paths only.
 *
 * Stubs out CollateralFilter, InterestRateModel, and PriceOracle abstracts —
 * tests in this PR exercise the deposit-side, not borrow-side, so a stub
 * collateral/rate/oracle is sufficient. The deploy ticket (per cycle-222
 * §11.C) selects the canonical concrete configuration for production.
 */
contract TestPool is Pool, ERC20DepositToken {
    constructor(address erc20DepositTokenImpl)
        Pool(address(0), address(0), address(0), new address[](0))
        ERC20DepositToken(erc20DepositTokenImpl)
    {}

    function initialize(address currencyToken_, uint64[] memory durations_, uint64[] memory rates_) external {
        Pool._initialize(currencyToken_, durations_, rates_);
    }

    function IMPLEMENTATION_NAME() external pure override returns (string memory) {
        return "TestPool";
    }

    function COLLATERAL_FILTER_NAME() external pure override returns (string memory) {
        return "TestCollateralFilter";
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
        return false;
    }

    function INTEREST_RATE_MODEL_NAME() external pure override returns (string memory) {
        return "TestInterestRateModel";
    }

    function INTEREST_RATE_MODEL_VERSION() external pure override returns (string memory) {
        return "0.0.0";
    }

    function _price(uint256 principal, uint64, LiquidityLogic.NodeSource[] memory, uint16, uint64[] memory, uint32)
        internal
        pure
        override
        returns (uint256 repayment, uint256 adminFee)
    {
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
