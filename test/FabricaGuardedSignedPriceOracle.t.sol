// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "../lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FabricaGuardedSignedPriceOracle} from "../src/FabricaGuardedSignedPriceOracle.sol";

contract MockERC1271Signer {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;
    bool internal _shouldRevert;
    mapping(bytes32 => mapping(bytes => bool)) internal _validSignatures;

    function setValidSignature(bytes32 hash, bytes memory signature, bool valid) external {
        _validSignatures[hash][signature] = valid;
    }

    function setShouldRevert(bool shouldRevert) external {
        _shouldRevert = shouldRevert;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (_shouldRevert) revert("ERC1271_REVERT");
        return _validSignatures[hash][signature] ? MAGIC_VALUE : bytes4(0);
    }
}

contract FabricaGuardedSignedPriceOracleV2 is FabricaGuardedSignedPriceOracle {
    function version2() external pure returns (uint256) {
        return 2;
    }
}

contract FabricaGuardedSignedPriceOracleTest is Test {
    event SignerUpdated(address indexed collateralToken, address indexed signer);
    event CollateralPolicyUpdated(
        address indexed collateralToken,
        address indexed currencyToken,
        uint64 maxQuoteAge,
        uint64 maxDuration,
        uint64 maxReferenceAge
    );
    event TokenPolicyUpdated(
        address indexed collateralToken,
        uint256 indexed tokenId,
        uint256 maxPrice,
        uint256 referencePrice,
        uint64 referenceUpdatedAt,
        uint16 maxDeviationBps
    );
    event CollateralEnabledUpdated(address indexed collateralToken, bool enabled);

    FabricaGuardedSignedPriceOracle internal oracle;
    MockERC1271Signer internal signerContract;
    address internal owner;
    address internal collateralToken;
    address internal currencyToken;
    address internal signer;
    string internal constant NAME = "All US Land";
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address token,uint256 tokenId,address currency,uint256 price,uint64 timestamp,uint64 duration)"
    );
    bytes32 internal constant OZ_V5_OWNER_SLOT = 0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300;

    function setUp() public {
        vm.warp(1_000_000);
        owner = makeAddr("owner");
        collateralToken = makeAddr("collateralToken");
        currencyToken = makeAddr("currencyToken");
        signerContract = new MockERC1271Signer();
        signer = address(signerContract);
        FabricaGuardedSignedPriceOracle impl = new FabricaGuardedSignedPriceOracle();
        bytes memory initData = abi.encodeCall(FabricaGuardedSignedPriceOracle.initialize, (owner, NAME));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        oracle = FabricaGuardedSignedPriceOracle(address(proxy));
        _configureCollateral();
        _configureToken(1, 1_000_000, 500_000, uint64(block.timestamp), 10_000);
        _enable(1);
    }

    function test_initializesOwnerAndEip712StorageBehindProxy() public view {
        assertEq(oracle.owner(), owner);
        assertEq(oracle.DOMAIN_VERSION(), "1");
        bytes32 ownerSlot = vm.load(address(oracle), OZ_V5_OWNER_SLOT);
        assertEq(address(uint160(uint256(ownerSlot))), owner);
    }

    function test_price_validErc1271QuotesReturnWeightedAverage() public {
        _configureToken(2, 1_000_000, 500_000, uint64(block.timestamp), 10_000);
        _enableMany(_ids(1, 2));
        uint256[] memory ids = _ids(1, 2);
        uint256[] memory quantities = _quantities(1, 3);
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](2);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        quotes[1] = _signedQuote(2, 200_000, uint64(block.timestamp), 60);
        assertEq(oracle.price(collateralToken, currencyToken, ids, quantities, abi.encode(quotes)), 175_000);
    }

    function test_price_validErc1271QuotePasses() public {
        MockERC1271Signer contractSigner = new MockERC1271Signer();
        bytes memory signature = hex"cafe";
        FabricaGuardedSignedPriceOracle.Quote memory quote = _quote(1, 300_000, uint64(block.timestamp), 60);
        contractSigner.setValidSignature(_digest(quote), signature, true);
        vm.prank(owner);
        oracle.setSigner(collateralToken, address(contractSigner));
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = FabricaGuardedSignedPriceOracle.SignedQuote(quote, signature);
        assertEq(oracle.price(collateralToken, currencyToken, _ids(1), _quantities(2), abi.encode(quotes)), 300_000);
    }

    function test_emitsPolicyEvents() public {
        address newCollateralToken = makeAddr("eventCollateralToken");
        address newSigner = address(new MockERC1271Signer());
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit SignerUpdated(newCollateralToken, newSigner);
        oracle.setSigner(newCollateralToken, newSigner);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit CollateralPolicyUpdated(newCollateralToken, currencyToken, 60, 90, 30 days);
        oracle.setCollateralPolicy(newCollateralToken, currencyToken, 60, 90, 30 days);
        vm.expectEmit(true, true, false, true, address(oracle));
        emit TokenPolicyUpdated(newCollateralToken, 7, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        oracle.setTokenPolicy(newCollateralToken, 7, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        vm.expectEmit(true, false, false, true, address(oracle));
        emit CollateralEnabledUpdated(newCollateralToken, true);
        oracle.setCollateralEnabled(newCollateralToken, true, _ids(7));
        vm.stopPrank();
    }

    function test_revert_missingCollateralConfig() public {
        FabricaGuardedSignedPriceOracle fresh = _freshOracle();
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.MissingCollateralConfig.selector, collateralToken)
        );
        fresh.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_marketDisabled() public {
        vm.prank(owner);
        oracle.setCollateralEnabled(collateralToken, false, new uint256[](0));
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.MarketDisabled.selector, collateralToken)
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_invalidLengths() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](0);
        vm.expectRevert(FabricaGuardedSignedPriceOracle.InvalidLength.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
        quotes = new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(FabricaGuardedSignedPriceOracle.InvalidLength.selector);
        oracle.price(collateralToken, currencyToken, _ids(1, 2), _quantities(1), abi.encode(quotes));
        vm.expectRevert(FabricaGuardedSignedPriceOracle.InvalidLength.selector);
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1, 2), abi.encode(quotes));
    }

    function test_revert_zeroQuantity() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.ZeroQuantity.selector, 0));
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(0), abi.encode(quotes));
    }

    function test_revert_quoteTokenMismatch() public {
        FabricaGuardedSignedPriceOracle.Quote memory quote = FabricaGuardedSignedPriceOracle.Quote(
            makeAddr("wrong"), 1, currencyToken, 100_000, uint64(block.timestamp), 60
        );
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _sign(quote);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaGuardedSignedPriceOracle.QuoteTokenMismatch.selector, collateralToken, 1, currencyToken
            )
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_currencyTokenMismatch() public {
        address wrongCurrency = makeAddr("wrongCurrency");
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaGuardedSignedPriceOracle.InvalidCurrencyToken.selector,
                collateralToken,
                currencyToken,
                wrongCurrency
            )
        );
        oracle.price(collateralToken, wrongCurrency, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quotePriceZero() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 0, uint64(block.timestamp), 60);
        vm.expectRevert(abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.QuotePriceZero.selector, 1));
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteDurationTooLong() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 301);
        vm.expectRevert(abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.QuoteDurationTooLong.selector, 301, 300));
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteStaleByAge() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp - 121), 300);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaGuardedSignedPriceOracle.QuoteStale.selector, block.timestamp - 121, 120, block.timestamp
            )
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteStaleByDurationExpiry() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp - 20), 10);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaGuardedSignedPriceOracle.QuoteStale.selector, block.timestamp - 20, 120, block.timestamp
            )
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteStaleByFutureTimestamp() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp + 1), 60);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaGuardedSignedPriceOracle.QuoteStale.selector, block.timestamp + 1, 120, block.timestamp
            )
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_invalidSigner() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = FabricaGuardedSignedPriceOracle.SignedQuote(
            _quote(1, 100_000, uint64(block.timestamp), 60), bytes("badsignature")
        );
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidSigner.selector, collateralToken, signer)
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_invalidSignerWhenErc1271Reverts() public {
        signerContract.setShouldRevert(true);
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = FabricaGuardedSignedPriceOracle.SignedQuote(
            _quote(1, 100_000, uint64(block.timestamp), 60), bytes("reverting")
        );
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidSigner.selector, collateralToken, signer)
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_missingTokenConfigDuringPrice() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(2, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.MissingTokenConfig.selector, collateralToken, 2)
        );
        oracle.price(collateralToken, currencyToken, _ids(2), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quotePriceExceedsCap() public {
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 1_000_001, uint64(block.timestamp), 60);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaGuardedSignedPriceOracle.QuotePriceExceedsCap.selector, 1, 1_000_001, 1_000_000
            )
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_referencePriceStale() public {
        vm.warp(block.timestamp + 31 days);
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.ReferencePriceStale.selector, 1, 1_000_000, 30 days)
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_quoteDeviationTooHigh() public {
        _configureToken(1, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        _enable(1);
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 600_001, uint64(block.timestamp), 60);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaGuardedSignedPriceOracle.QuoteDeviationTooHigh.selector, 1, 600_001, 500_000, 1_000
            )
        );
        oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes));
    }

    function test_revert_enableRequiresLiveTokenIds() public {
        vm.prank(owner);
        oracle.setCollateralEnabled(collateralToken, false, new uint256[](0));
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.TokenIdsRequired.selector, collateralToken)
        );
        vm.prank(owner);
        oracle.setCollateralEnabled(collateralToken, true, new uint256[](0));
    }

    function test_revert_partialConfigCannotEnable() public {
        vm.prank(owner);
        oracle.setCollateralEnabled(collateralToken, false, new uint256[](0));
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.MissingTokenConfig.selector, collateralToken, 2)
        );
        vm.prank(owner);
        oracle.setCollateralEnabled(collateralToken, true, _ids(1, 2));
    }

    function test_revert_setCollateralEnabledMissingCollateralConfig() public {
        uint256[] memory ids = _ids(1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FabricaGuardedSignedPriceOracle.MissingCollateralConfig.selector, makeAddr("newCollateral")
            )
        );
        vm.prank(owner);
        oracle.setCollateralEnabled(makeAddr("newCollateral"), true, ids);
    }

    function test_revert_adminValidation() public {
        vm.startPrank(owner);
        vm.expectRevert(FabricaGuardedSignedPriceOracle.ZeroAddress.selector);
        oracle.setSigner(address(0), signer);
        vm.expectRevert(FabricaGuardedSignedPriceOracle.ZeroAddress.selector);
        oracle.setSigner(collateralToken, address(0));
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidSignerContract.selector, makeAddr("eoa"))
        );
        oracle.setSigner(collateralToken, makeAddr("eoa"));
        vm.expectRevert(FabricaGuardedSignedPriceOracle.ZeroAddress.selector);
        oracle.setCollateralPolicy(address(0), currencyToken, 120, 300, 30 days);
        vm.expectRevert(FabricaGuardedSignedPriceOracle.ZeroAddress.selector);
        oracle.setCollateralPolicy(collateralToken, address(0), 120, 300, 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidCollateralPolicy.selector, collateralToken)
        );
        oracle.setCollateralPolicy(collateralToken, currencyToken, 0, 300, 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidCollateralPolicy.selector, collateralToken)
        );
        oracle.setCollateralPolicy(collateralToken, currencyToken, 120, 0, 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidCollateralPolicy.selector, collateralToken)
        );
        oracle.setCollateralPolicy(collateralToken, currencyToken, 120, 300, 0);
        vm.expectRevert(FabricaGuardedSignedPriceOracle.ZeroAddress.selector);
        oracle.setTokenPolicy(address(0), 3, 1_000_000, 500_000, uint64(block.timestamp), 1_000);
        vm.expectRevert(abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidDeviationBps.selector, 10_001));
        oracle.setTokenPolicy(collateralToken, 3, 1_000_000, 500_000, uint64(block.timestamp), 10_001);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidTokenPolicy.selector, collateralToken, 3)
        );
        oracle.setTokenPolicy(collateralToken, 3, 0, 500_000, uint64(block.timestamp), 1_000);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidTokenPolicy.selector, collateralToken, 3)
        );
        oracle.setTokenPolicy(collateralToken, 3, 1_000_000, 0, uint64(block.timestamp), 1_000);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidTokenPolicy.selector, collateralToken, 3)
        );
        oracle.setTokenPolicy(collateralToken, 3, 1_000_000, 500_000, 0, 1_000);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidTokenPolicy.selector, collateralToken, 3)
        );
        oracle.setTokenPolicy(collateralToken, 3, 1_000_000, 500_000, uint64(block.timestamp + 1), 1_000);
        vm.expectRevert(
            abi.encodeWithSelector(FabricaGuardedSignedPriceOracle.InvalidTokenPolicy.selector, collateralToken, 3)
        );
        oracle.setTokenPolicy(collateralToken, 3, 500_000, 500_001, uint64(block.timestamp), 1_000);
        vm.expectRevert(FabricaGuardedSignedPriceOracle.ZeroAddress.selector);
        oracle.setCollateralEnabled(address(0), false, new uint256[](0));
        vm.stopPrank();
    }

    function test_revert_emptyEip712DomainName() public {
        FabricaGuardedSignedPriceOracle impl = new FabricaGuardedSignedPriceOracle();
        bytes memory initData = abi.encodeCall(FabricaGuardedSignedPriceOracle.initialize, (owner, ""));
        vm.expectRevert(FabricaGuardedSignedPriceOracle.InvalidDomainName.selector);
        new ERC1967Proxy(address(impl), initData);
    }

    function test_revert_renounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(FabricaGuardedSignedPriceOracle.OwnershipRenounceDisabled.selector);
        oracle.renounceOwnership();
    }

    function test_upgradePreservesPoliciesAndPrice() public {
        FabricaGuardedSignedPriceOracleV2 newImpl = new FabricaGuardedSignedPriceOracleV2();
        vm.prank(owner);
        oracle.upgradeToAndCall(address(newImpl), "");
        assertEq(FabricaGuardedSignedPriceOracleV2(address(oracle)).version2(), 2);
        assertEq(oracle.owner(), owner);
        FabricaGuardedSignedPriceOracle.CollateralPolicy memory policy = oracle.collateralPolicy(collateralToken);
        assertEq(policy.signer, signer);
        assertEq(policy.currencyToken, currencyToken);
        assertEq(policy.maxQuoteAge, 120);
        assertEq(policy.maxDuration, 300);
        assertEq(policy.maxReferenceAge, 30 days);
        assertTrue(policy.enabled);
        assertTrue(policy.configured);
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](1);
        quotes[0] = _signedQuote(1, 100_000, uint64(block.timestamp), 60);
        assertEq(oracle.price(collateralToken, currencyToken, _ids(1), _quantities(1), abi.encode(quotes)), 100_000);
    }

    function test_revert_onlyOwnerCanUpgrade() public {
        FabricaGuardedSignedPriceOracleV2 newImpl = new FabricaGuardedSignedPriceOracleV2();
        vm.expectRevert();
        oracle.upgradeToAndCall(address(newImpl), "");
    }

    function testFuzz_weightedAggregateCannotExceedConfiguredCaps(
        uint128 rawPriceA,
        uint128 rawPriceB,
        uint64 rawQuantityA,
        uint64 rawQuantityB
    ) public {
        uint256 priceA = bound(uint256(rawPriceA), 1, 1_000_000);
        uint256 priceB = bound(uint256(rawPriceB), 1, 1_000_000);
        uint256 quantityA = bound(uint256(rawQuantityA), 1, 1_000_000);
        uint256 quantityB = bound(uint256(rawQuantityB), 1, 1_000_000);
        _configureToken(2, 1_000_000, 500_000, uint64(block.timestamp), 10_000);
        _enableMany(_ids(1, 2));
        FabricaGuardedSignedPriceOracle.SignedQuote[] memory quotes =
            new FabricaGuardedSignedPriceOracle.SignedQuote[](2);
        quotes[0] = _signedQuote(1, priceA, uint64(block.timestamp), 60);
        quotes[1] = _signedQuote(2, priceB, uint64(block.timestamp), 60);
        uint256 aggregate = oracle.price(
            collateralToken, currencyToken, _ids(1, 2), _quantities(quantityA, quantityB), abi.encode(quotes)
        );
        assertLe(aggregate, 1_000_000);
    }

    function _freshOracle() internal returns (FabricaGuardedSignedPriceOracle fresh) {
        FabricaGuardedSignedPriceOracle impl = new FabricaGuardedSignedPriceOracle();
        bytes memory initData = abi.encodeCall(FabricaGuardedSignedPriceOracle.initialize, (owner, NAME));
        fresh = FabricaGuardedSignedPriceOracle(address(new ERC1967Proxy(address(impl), initData)));
    }

    function _configureCollateral() internal {
        vm.startPrank(owner);
        oracle.setSigner(collateralToken, signer);
        oracle.setCollateralPolicy(collateralToken, currencyToken, 120, 300, 30 days);
        vm.stopPrank();
    }

    function _configureToken(
        uint256 tokenId,
        uint256 maxPrice,
        uint256 referencePrice,
        uint64 referenceUpdatedAt,
        uint16 maxDeviationBps
    ) internal {
        vm.prank(owner);
        oracle.setTokenPolicy(collateralToken, tokenId, maxPrice, referencePrice, referenceUpdatedAt, maxDeviationBps);
    }

    function _enable(uint256 tokenId) internal {
        vm.prank(owner);
        oracle.setCollateralEnabled(collateralToken, true, _ids(tokenId));
    }

    function _enableMany(uint256[] memory tokenIds) internal {
        vm.prank(owner);
        oracle.setCollateralEnabled(collateralToken, true, tokenIds);
    }

    function _signedQuote(uint256 tokenId, uint256 quotePrice, uint64 timestamp, uint64 duration)
        internal
        returns (FabricaGuardedSignedPriceOracle.SignedQuote memory)
    {
        return _sign(_quote(tokenId, quotePrice, timestamp, duration));
    }

    function _quote(uint256 tokenId, uint256 quotePrice, uint64 timestamp, uint64 duration)
        internal
        view
        returns (FabricaGuardedSignedPriceOracle.Quote memory)
    {
        return FabricaGuardedSignedPriceOracle.Quote(
            collateralToken, tokenId, currencyToken, quotePrice, timestamp, duration
        );
    }

    function _sign(FabricaGuardedSignedPriceOracle.Quote memory quote)
        internal
        returns (FabricaGuardedSignedPriceOracle.SignedQuote memory)
    {
        bytes memory signature = abi.encodePacked(
            quote.token, quote.tokenId, quote.currency, quote.price, quote.timestamp, quote.duration
        );
        signerContract.setValidSignature(_digest(quote), signature, true);
        return FabricaGuardedSignedPriceOracle.SignedQuote(quote, signature);
    }

    function _digest(FabricaGuardedSignedPriceOracle.Quote memory quote) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(NAME)),
                keccak256(bytes(oracle.DOMAIN_VERSION())),
                block.chainid,
                address(oracle)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH, quote.token, quote.tokenId, quote.currency, quote.price, quote.timestamp, quote.duration
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _ids(uint256 a) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = a;
    }

    function _ids(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _quantities(uint256 a) internal pure returns (uint256[] memory quantities) {
        quantities = new uint256[](1);
        quantities[0] = a;
    }

    function _quantities(uint256 a, uint256 b) internal pure returns (uint256[] memory quantities) {
        quantities = new uint256[](2);
        quantities[0] = a;
        quantities[1] = b;
    }
}
