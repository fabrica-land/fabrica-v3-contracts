// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";

interface IFVTokenProxy {
    function implementation() external view returns (address);
    function defaultValidator() external view returns (address);
}

interface IFVFeeCollectorProxy {
    function implementation() external view returns (address);
    function owner() external view returns (address);
    function protocolContractAddress() external view returns (address);
    function collectFee(
        uint256 tokenId,
        string calldata feeType,
        address obligor,
        address erc20CurrencyAddress,
        uint256 amount
    ) external;
}

contract FVMockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Eng2556Eng3450SepoliaForkFVTest is Test {
    address internal constant TOKEN_PROXY = 0xb52ED2Dc8EBD49877De57De3f454Fd71b75bc1fD;
    address internal constant TOKEN_IMPL = 0x632eB7A76041B33b070213Cf11d518e84E556391;
    address internal constant FEE_PROXY = 0x404f53869aD67e167a8C89035f55572e653d7B22;
    address internal constant FEE_IMPL = 0x38EA0c1c84E51ce5dA0a266c0E33DDDb91fFc296;
    address internal constant LIVE_DEFAULT_VALIDATOR = 0xAAA7FDc1A573965a2eD47Ab154332b6b55098008;
    address internal constant OBLIGOR = address(0x0B119012);
    uint256 internal constant FORK_BLOCK = 11_218_223;
    uint256 internal constant DEFAULT_VALIDATOR_SLOT = 304;

    function setUp() public {
        vm.createSelectFork("sepolia", FORK_BLOCK);
    }

    function test_fork_collectFee_revertsWhenResolvedValidatorZeroAfterSepoliaUpgrade() public {
        IFVTokenProxy token = IFVTokenProxy(TOKEN_PROXY);
        IFVFeeCollectorProxy collector = IFVFeeCollectorProxy(FEE_PROXY);
        assertEq(token.implementation(), TOKEN_IMPL, "token impl must be upgraded");
        assertEq(collector.implementation(), FEE_IMPL, "fee collector impl must be upgraded");
        assertEq(collector.protocolContractAddress(), TOKEN_PROXY, "collector must read upgraded token proxy");
        assertEq(token.defaultValidator(), LIVE_DEFAULT_VALIDATOR, "live default validator is nonzero");

        vm.store(TOKEN_PROXY, bytes32(DEFAULT_VALIDATOR_SLOT), bytes32(0));
        assertEq(token.defaultValidator(), address(0), "fork setup must zero default validator");

        FVMockERC20 currency = new FVMockERC20();
        currency.mint(OBLIGOR, 1_000);
        vm.prank(OBLIGOR);
        currency.approve(FEE_PROXY, 1_000);

        vm.prank(collector.owner());
        vm.expectRevert(FabricaFeeCollector.ValidatorAddressZero.selector);
        collector.collectFee(1, "onramp", OBLIGOR, address(currency), 1_000);
        assertEq(currency.balanceOf(OBLIGOR), 1_000, "revert must roll back token transfer");
    }
}
