// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice ENG-3922 — measures `price()` gas from inside a real Sepolia transaction.
/// @dev `price()` is a view, so an `eth_call` costs nothing observable and a fork measurement is
///      the harness's own accounting. This probe makes the read happen inside a transaction and
///      emits what it consumed, so the read numbers in the report have a Sepolia receipt behind
///      them rather than only a Foundry figure.
contract PriceGasProbe {
    event PriceGas(address indexed arm, uint256 indexed tokenId, uint256 gasUsed, uint256 priceUsdc6);
    event PriceReverted(address indexed arm, uint256 indexed tokenId, uint256 gasUsed, bytes reason);

    function probe(address arm, address collateralToken, address currencyToken, uint256 tokenId, bytes calldata ctx)
        external
        returns (uint256 gasUsed, uint256 priceUsdc6)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256[] memory qty = new uint256[](1);
        qty[0] = 1;
        uint256 before = gasleft();
        try IPriceOracle(arm).price(collateralToken, currencyToken, ids, qty, ctx) returns (uint256 p) {
            gasUsed = before - gasleft();
            priceUsdc6 = p;
            emit PriceGas(arm, tokenId, gasUsed, p);
        } catch (bytes memory reason) {
            gasUsed = before - gasleft();
            emit PriceReverted(arm, tokenId, gasUsed, reason);
        }
    }
}
