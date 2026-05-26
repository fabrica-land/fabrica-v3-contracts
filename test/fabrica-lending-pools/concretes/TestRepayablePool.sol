// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../../../src/fabrica-lending-pools/Pool.sol";
import "../../../src/fabrica-lending-pools/tokenization/ERC20DepositToken.sol";

/**
 * @title Concrete Pool that exercises the borrow → repay path end-to-end.
 *
 * Stubs:
 *   - Permissive collateral filter (any token + id supported).
 *   - Trivial price oracle returning 0 (tick limits resolve to absolute values).
 *   - Trivial interest rate model: repayment = principal, adminFee = 0.
 *     This keeps the repay math obvious in tests without compromising the
 *     access-control surface (the change in ENG-3076 is who-may-call, not
 *     how repayment is priced).
 *
 * Uses the base Pool._transferCollateral ERC721 path for collateral.
 */
contract TestRepayablePool is Pool, ERC20DepositToken {
    constructor(address erc20DepositTokenImpl)
        Pool(address(0), address(0), address(0), new address[](0))
        ERC20DepositToken(erc20DepositTokenImpl)
    {}

    function initialize(address currencyToken_, uint64[] memory durations_, uint64[] memory rates_) external {
        Pool._initialize(currencyToken_, durations_, rates_);
    }

    function IMPLEMENTATION_NAME() external pure override returns (string memory) {
        return "TestRepayablePool";
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
