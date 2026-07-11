// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Header layout copied from MetaStreet contracts v2 LoanReceipt at commit
/// 8ed467d272a2cee35751e60851fa1b830e2fe018 (Fabrica's vendored receipt version 2).
library SettlementLoanReceipt {
    error InvalidReceiptEncoding();

    uint256 private constant _HEADER_SIZE = 187;
    uint256 private constant _NODE_SIZE = 48;

    struct Details {
        uint256 maxRepayment;
        address borrower;
        address collateralToken;
        uint256 collateralTokenId;
    }

    function decode(bytes calldata receipt) internal pure returns (Details memory details) {
        if (receipt.length < _HEADER_SIZE || uint8(receipt[0]) != 2) revert InvalidReceiptEncoding();
        uint256 contextLength = uint16(bytes2(receipt[185:187]));
        if (receipt.length < _HEADER_SIZE + contextLength) revert InvalidReceiptEncoding();
        if ((receipt.length - _HEADER_SIZE - contextLength) % _NODE_SIZE != 0) revert InvalidReceiptEncoding();

        details.maxRepayment = uint256(bytes32(receipt[33:65]));
        details.borrower = address(uint160(bytes20(receipt[97:117])));
        details.collateralToken = address(uint160(bytes20(receipt[133:153])));
        details.collateralTokenId = uint256(bytes32(receipt[153:185]));
    }
}
