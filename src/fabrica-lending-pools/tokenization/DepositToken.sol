// SPDX-License-Identifier: MIT
// Vendored from metastreet-labs/metastreet-contracts-v2 @ 8ed467d272a2cee35751e60851fa1b830e2fe018
// Modifications: see git history of this file in fabrica-land/fabrica-v3-contracts.
pragma solidity ^0.8.0;

/**
 * @title Deposit Token API
 * @author MetaStreet Labs
 */
abstract contract DepositToken {
    /**************************************************************************/
    /* Events */
    /**************************************************************************/

    /**
     * @notice Emitted when deposit token created
     * @param instance Instance address
     * @param implementation Implementation address
     * @param tick Tick
     */
    event TokenCreated(address indexed instance, address indexed implementation, uint128 indexed tick);

    /**************************************************************************/
    /* API */
    /**************************************************************************/

    /**
     * @notice Get the deposit token address for tick
     *
     * @param tick Tick
     * @return Deposit token address
     */
    function depositToken(uint128 tick) public view virtual returns (address);

    /**
     * @notice Tokenize a tick
     *
     * @param tick Tick
     * @return Deposit token address
     */
    function _tokenize(uint128 tick) internal virtual returns (address);

    /**
     * @notice Hook called by Pool on token transfers
     *
     * @param from From
     * @param to To
     * @param tick Tick
     * @param shares Shares
     */
    function _onExternalTransfer(address from, address to, uint128 tick, uint256 shares) internal virtual;
}
