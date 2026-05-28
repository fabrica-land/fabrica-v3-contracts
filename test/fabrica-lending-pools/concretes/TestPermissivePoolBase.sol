// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../../../src/fabrica-lending-pools/Pool.sol";
import "../../../src/fabrica-lending-pools/tokenization/ERC20DepositToken.sol";

/**
 * @title Shared stubs for concrete test pools that exercise the borrow →
 * repay / liquidate path end-to-end.
 *
 * Stubs:
 *   - Permissive collateral filter (any token + id supported).
 *   - Trivial price oracle returning 0 (tick limits resolve to absolute values).
 *   - Trivial interest rate model: repayment = principal, adminFee = 0.
 *     This keeps the repay/liquidate math obvious in tests without compromising
 *     the access-control / time-gate surface under test.
 *
 * Concrete subclasses supply only their constructor (collateral liquidator,
 * grace period, etc.) and IMPLEMENTATION_NAME. Uses the base
 * Pool._transferCollateral ERC721 path for collateral.
 */
abstract contract TestPermissivePoolBase is Pool, ERC20DepositToken {
    function initialize(address currencyToken_, uint64[] memory durations_, uint64[] memory rates_) external {
        Pool._initialize(currencyToken_, durations_, rates_);
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
