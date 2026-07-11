// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISettlementMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface ISettlementMorphoFlashLoanCallback {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}
