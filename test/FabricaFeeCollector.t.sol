// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {FabricaFeeCollector} from "../src/FabricaFeeCollector.sol";
import {FabricaProxy} from "../src/FabricaProxy.sol";
import {IFabricaToken} from "../src/IFabricaToken.sol";

// Standard ERC-20: moves balances and returns a bool, like USDC/DAI.
contract MockERC20Compliant {
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

// A token whose transfer()/transferFrom() silently fail: no balance movement,
// `false` returned instead of reverting. Mirrors tokens like legacy BNB.
contract MockERC20ReturnsFalse {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

// A token that moves balances correctly but returns no data at all, like
// mainnet USDT. Strict ABI decoding of a `bool` return reverts on empty
// returndata unless the caller uses SafeERC20.
contract MockERC20NoReturn {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract MockFabricaToken is IFabricaToken {
    address public defaultValidator;
    address private _validator;

    constructor(address defaultValidator_, address validator_) {
        defaultValidator = defaultValidator_;
        _validator = validator_;
    }

    function _property(uint256) external view returns (uint256, string memory, string memory, string memory, address) {
        return (0, "", "", "", _validator);
    }

    function setDefaultValidator(address) external {}
    function setValidatorRegistry(address) external {}

    function validatorRegistry() external view returns (address) {
        return address(0);
    }

    function mint(address[] memory, uint256, uint256[] memory, string memory, string memory, string memory, address)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function mintBatch(
        address[] memory,
        uint256[] memory,
        uint256[] memory,
        string[] memory,
        string[] memory,
        string[] memory,
        address[] memory
    ) external pure returns (uint256[] memory ids) {
        return ids;
    }

    function burn(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function burnBatch(address, uint256[] memory, uint256[] memory) external pure returns (bool) {
        return true;
    }

    function generateId(address, uint256, string memory) external pure returns (uint256) {
        return 0;
    }

    function updateOperatingAgreement(string memory, uint256) external pure returns (bool) {
        return true;
    }

    function updateConfiguration(string memory, uint256) external pure returns (bool) {
        return true;
    }

    function updateValidator(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract FabricaFeeCollectorTest is Test {
    FabricaFeeCollector public collector;
    MockFabricaToken public protocolContract;
    address public proxyAdmin = address(0xAD);
    address public owner = address(this);
    address public protocolFeeRecipient = address(0xFEE);
    address public defaultValidator = address(0xDEFA07);
    address public validator = address(0xA11DA70);
    address public obligor = address(0x0B119012);

    function _deployCollectorFor(address protocolContractAddress_, uint8 protocolSharePercent_)
        internal
        returns (FabricaFeeCollector)
    {
        FabricaFeeCollector impl = new FabricaFeeCollector();
        bytes memory initData = abi.encodeCall(
            FabricaFeeCollector.initialize, (protocolContractAddress_, protocolSharePercent_, protocolFeeRecipient)
        );
        FabricaProxy proxy = new FabricaProxy(address(impl), proxyAdmin, initData);
        return FabricaFeeCollector(address(proxy));
    }

    function _deployCollector(uint8 protocolSharePercent_) internal returns (FabricaFeeCollector) {
        return _deployCollectorFor(address(protocolContract), protocolSharePercent_);
    }

    function _setupApprovedCollection(address defaultValidator_, address validator_)
        internal
        returns (FabricaFeeCollector configuredCollector, MockERC20Compliant currency)
    {
        return _setupApprovedCollection(defaultValidator_, validator_, 10);
    }

    function _setupApprovedCollection(address defaultValidator_, address validator_, uint8 protocolSharePercent_)
        internal
        returns (FabricaFeeCollector configuredCollector, MockERC20Compliant currency)
    {
        MockFabricaToken tokenContract = new MockFabricaToken(defaultValidator_, validator_);
        configuredCollector = _deployCollectorFor(address(tokenContract), protocolSharePercent_);
        currency = new MockERC20Compliant();
        currency.mint(obligor, 1_000);
        vm.prank(obligor);
        currency.approve(address(configuredCollector), 1_000);
    }

    function setUp() public {
        protocolContract = new MockFabricaToken(defaultValidator, validator);
        collector = _deployCollector(10);
    }

    // ENG-2548: initialize() must reject an out-of-range share percent.
    function test_initialize_revertsAboveMax() public {
        FabricaFeeCollector impl = new FabricaFeeCollector();
        bytes memory initData =
            abi.encodeCall(FabricaFeeCollector.initialize, (address(protocolContract), 101, protocolFeeRecipient));
        vm.expectRevert(abi.encodeWithSelector(FabricaFeeCollector.ProtocolSharePercentExceedsMaximum.selector, 101));
        new FabricaProxy(address(impl), proxyAdmin, initData);
    }

    function test_initialize_succeedsAtMax() public {
        FabricaFeeCollector c = _deployCollector(100);
        assertEq(c.protocolSharePercent(), 100);
    }

    // ENG-2548: setProtocolSharePercent must reject anything above 100.
    function test_setProtocolSharePercent_revertsAboveMax() public {
        vm.expectRevert(abi.encodeWithSelector(FabricaFeeCollector.ProtocolSharePercentExceedsMaximum.selector, 101));
        collector.setProtocolSharePercent(101);
    }

    function test_setProtocolSharePercent_revertsAtMaxUint8() public {
        vm.expectRevert(abi.encodeWithSelector(FabricaFeeCollector.ProtocolSharePercentExceedsMaximum.selector, 255));
        collector.setProtocolSharePercent(255);
    }

    function test_setProtocolSharePercent_succeedsAtMax() public {
        collector.setProtocolSharePercent(100);
        assertEq(collector.protocolSharePercent(), 100);
    }

    function test_setProtocolSharePercent_succeedsBelowMax() public {
        collector.setProtocolSharePercent(50);
        assertEq(collector.protocolSharePercent(), 50);
    }

    // ENG-3426: initialize() must reject a zero protocol contract address.
    function test_initialize_revertsOnZeroProtocolContract() public {
        FabricaFeeCollector impl = new FabricaFeeCollector();
        bytes memory initData = abi.encodeCall(FabricaFeeCollector.initialize, (address(0), 10, protocolFeeRecipient));
        vm.expectRevert(FabricaFeeCollector.ProtocolContractAddressZero.selector);
        new FabricaProxy(address(impl), proxyAdmin, initData);
    }

    // ENG-3426: initialize() must reject a zero protocol fee recipient.
    function test_initialize_revertsOnZeroFeeRecipient() public {
        FabricaFeeCollector impl = new FabricaFeeCollector();
        bytes memory initData =
            abi.encodeCall(FabricaFeeCollector.initialize, (address(protocolContract), 10, address(0)));
        vm.expectRevert(FabricaFeeCollector.ProtocolFeeRecipientZero.selector);
        new FabricaProxy(address(impl), proxyAdmin, initData);
    }

    // ENG-3426: initialize() persists both addresses when they are non-zero.
    function test_initialize_succeedsWithNonZeroAddresses() public {
        FabricaFeeCollector c = _deployCollector(10);
        assertEq(c.protocolContractAddress(), address(protocolContract));
        assertEq(c.protocolFeeRecipient(), protocolFeeRecipient);
    }

    // ENG-3426: setProtocolFeeRecipient must reject the zero address.
    function test_setProtocolFeeRecipient_revertsOnZero() public {
        vm.expectRevert(FabricaFeeCollector.ProtocolFeeRecipientZero.selector);
        collector.setProtocolFeeRecipient(address(0));
    }

    // ENG-3426: setProtocolFeeRecipient updates state for a non-zero address.
    function test_setProtocolFeeRecipient_succeedsOnNonZero() public {
        address newRecipient = address(0xB0B);
        collector.setProtocolFeeRecipient(newRecipient);
        assertEq(collector.protocolFeeRecipient(), newRecipient);
    }

    // ENG-2547: collectFee on a standard, boolean-compliant ERC-20 works and
    // splits funds correctly between protocol and validator.
    function test_collectFee_compliantToken_movesFundsAndSplits() public {
        MockERC20Compliant token = new MockERC20Compliant();
        token.mint(obligor, 1_000);
        vm.prank(obligor);
        token.approve(address(collector), 1_000);

        collector.collectFee(1, "onramp", obligor, address(token), 1_000);

        // protocolSharePercent is 10 -> protocol gets 100, validator gets 900.
        assertEq(token.balanceOf(protocolFeeRecipient), 100);
        assertEq(token.balanceOf(validator), 900);
        assertEq(token.balanceOf(obligor), 0);
        assertEq(token.balanceOf(address(collector)), 0);
    }

    // ENG-3450: when the per-token validator is zero, collectFee must fall
    // back to the token contract's non-zero default validator.
    function test_collectFee_usesDefaultValidatorWhenTokenValidatorZero() public {
        (FabricaFeeCollector configuredCollector, MockERC20Compliant token) =
            _setupApprovedCollection(defaultValidator, address(0));
        configuredCollector.collectFee(1, "onramp", obligor, address(token), 1_000);
        assertEq(token.balanceOf(protocolFeeRecipient), 100);
        assertEq(token.balanceOf(defaultValidator), 900);
        assertEq(token.balanceOf(address(0)), 0);
    }

    // ENG-3450: if both the per-token validator and default validator resolve
    // to zero, collectFee must revert before the validator share can burn.
    function test_collectFee_revertsWhenResolvedValidatorZero() public {
        (FabricaFeeCollector configuredCollector, MockERC20Compliant token) =
            _setupApprovedCollection(address(0), address(0));
        vm.expectRevert(FabricaFeeCollector.ValidatorAddressZero.selector);
        configuredCollector.collectFee(1, "onramp", obligor, address(token), 1_000);
        assertEq(token.balanceOf(protocolFeeRecipient), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(obligor), 1_000);
    }

    // ENG-3450: resolved validator validation is unconditional, even when a
    // 100% protocol share would leave no validator transfer to execute.
    function test_collectFee_revertsWhenResolvedValidatorZeroAtFullProtocolShare() public {
        (FabricaFeeCollector configuredCollector, MockERC20Compliant token) =
            _setupApprovedCollection(address(0), address(0), 100);
        vm.expectRevert(FabricaFeeCollector.ValidatorAddressZero.selector);
        configuredCollector.collectFee(1, "onramp", obligor, address(token), 1_000);
        assertEq(token.balanceOf(protocolFeeRecipient), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(obligor), 1_000);
    }

    // ENG-2547: a token that returns `false` instead of reverting on failure
    // must cause collectFee to revert via SafeERC20, not silently succeed.
    function test_collectFee_falseReturningToken_reverts() public {
        MockERC20ReturnsFalse token = new MockERC20ReturnsFalse();
        token.mint(obligor, 1_000);
        vm.prank(obligor);
        token.approve(address(collector), 1_000);

        vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(token)));
        collector.collectFee(1, "onramp", obligor, address(token), 1_000);
    }

    // ENG-2547: a token that returns no data at all (USDT-style) must be
    // tolerated by SafeERC20 rather than reverting on empty returndata.
    function test_collectFee_noReturnToken_movesFunds() public {
        MockERC20NoReturn token = new MockERC20NoReturn();
        token.mint(obligor, 1_000);
        vm.prank(obligor);
        token.approve(address(collector), 1_000);

        collector.collectFee(1, "onramp", obligor, address(token), 1_000);

        assertEq(token.balanceOf(protocolFeeRecipient), 100);
        assertEq(token.balanceOf(validator), 900);
        assertEq(token.balanceOf(obligor), 0);
    }
}
