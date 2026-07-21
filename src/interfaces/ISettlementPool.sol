// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISettlementPool {
    function currencyToken() external view returns (address);
    function repay(bytes calldata encodedLoanReceipt) external;
}
