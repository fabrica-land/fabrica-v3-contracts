// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {ForkTestBase} from "./ForkTestBase.sol";
import {MockERC20Compliant} from "./FabricaFeeCollector.t.sol";

contract Eng2556Eng3450SepoliaForkFVTest is ForkTestBase {
    address internal constant TOKEN_PROXY = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    address internal constant TOKEN_IMPL = 0x632eB7A76041B33b070213Cf11d518e84E556391;
    address internal constant FEE_PROXY_PROD = 0x404f53869aD67e167a8C89035f55572e653d7B22;
    address internal constant FEE_PROXY_STAGING = 0x98e819BF78081f4343E71Ed4096C59d74948C166;
    address internal constant FEE_PROXY_DEVELOP = 0x24888646723ae14C83E5354431753675A3d12D3c;
    address internal constant FEE_IMPL = 0x38EA0c1c84E51ce5dA0a266c0E33DDDb91fFc296;
    address internal constant LIVE_DEFAULT_VALIDATOR = 0xAAA7FDc1A573965a2eD47Ab154332b6b55098008;
    address internal constant OBLIGOR = address(0x0B119012);
    uint256 internal constant FORK_BLOCK = 11_218_223;
    uint256 internal constant DEFAULT_VALIDATOR_SLOT = 304;

    function setUp() public {
        _forkOrRequire(ForkConfig("SEPOLIA_RPC_URL", "sepolia", FORK_BLOCK, "FABRICA_REQUIRE_SEPOLIA_FV"));
    }

    function test_fork_collectFee_revertsWhenResolvedValidatorZeroAfterSepoliaUpgrade() public {
        FabricaToken token = FabricaToken(TOKEN_PROXY);
        assertEq(token.implementation(), TOKEN_IMPL, "token impl must be upgraded");
        assertEq(token.defaultValidator(), LIVE_DEFAULT_VALIDATOR, "live default validator is nonzero");
        vm.store(TOKEN_PROXY, bytes32(DEFAULT_VALIDATOR_SLOT), bytes32(0));
        assertEq(token.defaultValidator(), address(0), "fork setup must zero default validator");
        _verifyCollector(FEE_PROXY_PROD);
        _verifyCollector(FEE_PROXY_STAGING);
        _verifyCollector(FEE_PROXY_DEVELOP);
    }

    function _verifyCollector(address feeProxy) internal {
        FabricaFeeCollector collector = FabricaFeeCollector(feeProxy);
        assertEq(collector.implementation(), FEE_IMPL, "fee collector impl must be upgraded");
        assertEq(collector.protocolContractAddress(), TOKEN_PROXY, "collector must read upgraded token proxy");
        MockERC20Compliant currency = new MockERC20Compliant();
        currency.mint(OBLIGOR, 1_000);
        vm.prank(OBLIGOR);
        currency.approve(feeProxy, 1_000);
        vm.prank(collector.owner());
        vm.expectRevert(FabricaFeeCollector.ValidatorAddressZero.selector);
        collector.collectFee(1, "onramp", OBLIGOR, address(currency), 1_000);
        assertEq(currency.balanceOf(OBLIGOR), 1_000, "revert must roll back token transfer");
    }
}
