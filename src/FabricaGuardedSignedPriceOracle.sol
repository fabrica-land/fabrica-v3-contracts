// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SignatureChecker} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import {
    EIP712Upgradeable
} from "../lib/openzeppelin-contracts-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";

/// @notice Guarded signed price oracle for Fabrica lending pools.
/// @dev Fresh UUPS oracle; existing pools must be cut over by creating/configuring a new pool.
contract FabricaGuardedSignedPriceOracle is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    EIP712Upgradeable,
    IPriceOracle
{
    /// @notice Basis point denominator used for deviation checks.
    uint256 public constant BASIS_POINTS = 10_000;
    /// @notice Implementation version for deployment and monitoring readback.
    string public constant IMPLEMENTATION_VERSION = "1.0.0";
    /// @notice EIP-712 signing domain version.
    string public constant DOMAIN_VERSION = "1";
    /// @notice EIP-712 quote struct typehash.
    bytes32 public constant QUOTE_TYPEHASH = keccak256(
        "Quote(address token,uint256 tokenId,address currency,uint256 price,uint64 timestamp,uint64 duration)"
    );

    struct Quote {
        address token;
        uint256 tokenId;
        address currency;
        uint256 price;
        uint64 timestamp;
        uint64 duration;
    }

    struct SignedQuote {
        Quote quote;
        bytes signature;
    }

    struct CollateralPolicy {
        address signer;
        address currencyToken;
        uint64 maxQuoteAge;
        uint64 maxDuration;
        uint64 maxReferenceAge;
        bool enabled;
        bool configured;
    }

    struct TokenPolicy {
        uint256 maxPrice;
        uint256 referencePrice;
        uint64 referenceUpdatedAt;
        uint16 maxDeviationBps;
        bool configured;
    }

    error InvalidLength();
    error ZeroAddress();
    error ZeroQuantity(uint256 index);
    error MarketDisabled(address collateralToken);
    error MissingCollateralConfig(address collateralToken);
    error MissingTokenConfig(address collateralToken, uint256 tokenId);
    error QuoteTokenMismatch(address expectedToken, uint256 expectedTokenId, address expectedCurrency);
    error QuotePriceZero(uint256 tokenId);
    error QuoteDurationTooLong(uint256 duration, uint256 maxDuration);
    error QuoteStale(uint256 timestamp, uint256 maxAge, uint256 currentTimestamp);
    error InvalidSigner(address collateralToken, address configuredSigner);
    error InvalidCurrencyToken(address collateralToken, address expectedCurrency, address actualCurrency);
    error QuotePriceExceedsCap(uint256 tokenId, uint256 price, uint256 maxPrice);
    error ReferencePriceStale(uint256 tokenId, uint256 referenceUpdatedAt, uint256 maxReferenceAge);
    error QuoteDeviationTooHigh(uint256 tokenId, uint256 price, uint256 referencePrice, uint256 maxDeviationBps);
    error InvalidCollateralPolicy(address collateralToken);
    error InvalidTokenPolicy(address collateralToken, uint256 tokenId);
    error InvalidDeviationBps(uint256 maxDeviationBps);
    error TokenIdsRequired(address collateralToken);
    error InvalidSignerContract(address signer);
    error InvalidDomainName();
    error OwnershipRenounceDisabled();

    /// @notice Emitted when the ERC-1271 signer is changed for a collateral token.
    /// @param collateralToken Collateral contract governed by the signer.
    /// @param signer Contract signer that must validate future quotes.
    event SignerUpdated(address indexed collateralToken, address indexed signer);
    /// @notice Emitted when collateral-wide quote freshness and duration bounds are changed.
    /// @param collateralToken Collateral contract governed by the policy.
    /// @param currencyToken Only currency token accepted for this collateral market.
    /// @param maxQuoteAge Maximum quote age in seconds.
    /// @param maxDuration Maximum signed quote duration in seconds.
    /// @param maxReferenceAge Maximum reference-price age in seconds.
    event CollateralPolicyUpdated(
        address indexed collateralToken,
        address indexed currencyToken,
        uint64 maxQuoteAge,
        uint64 maxDuration,
        uint64 maxReferenceAge
    );
    /// @notice Emitted when token-level cap and reference-price bounds are changed.
    /// @param collateralToken Collateral contract containing the token.
    /// @param tokenId Token ID governed by the policy.
    /// @param maxPrice Hard maximum signed price for this token ID.
    /// @param referencePrice Governance reference price for deviation checks.
    /// @param referenceUpdatedAt Timestamp when the reference price was set.
    /// @param maxDeviationBps Maximum allowed deviation from the reference price.
    event TokenPolicyUpdated(
        address indexed collateralToken,
        uint256 indexed tokenId,
        uint256 maxPrice,
        uint256 referencePrice,
        uint64 referenceUpdatedAt,
        uint16 maxDeviationBps
    );
    /// @notice Emitted when a collateral market is enabled or disabled.
    /// @param collateralToken Collateral contract governed by the switch.
    /// @param enabled True when the collateral can return prices.
    event CollateralEnabledUpdated(address indexed collateralToken, bool enabled);

    mapping(address => CollateralPolicy) private _collateralPolicies;
    mapping(address => mapping(uint256 => TokenPolicy)) private _tokenPolicies;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the oracle proxy.
    /// @param initialOwner Safe or owner that controls policy and upgrades.
    /// @param name EIP-712 signing domain name.
    function initialize(address initialOwner, string memory name) external initializer {
        if (bytes(name).length == 0) revert InvalidDomainName();
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __EIP712_init(name, DOMAIN_VERSION);
    }

    /// @notice Return collateral-level policy.
    /// @param collateralToken Collateral contract governed by the policy.
    /// @return policy Current collateral-level policy.
    function collateralPolicy(address collateralToken) external view returns (CollateralPolicy memory) {
        return _collateralPolicies[collateralToken];
    }

    /// @notice Return token-level policy.
    /// @param collateralToken Collateral contract containing the token.
    /// @param tokenId Token ID governed by the policy.
    /// @return policy Current token-level policy.
    function tokenPolicy(address collateralToken, uint256 tokenId) external view returns (TokenPolicy memory) {
        return _tokenPolicies[collateralToken][tokenId];
    }

    /// @notice Set the Safe/ERC-1271 signer for a collateral token.
    /// @param collateralToken Collateral contract governed by the signer.
    /// @param signer Contract signer that must validate future quotes.
    function setSigner(address collateralToken, address signer) external onlyOwner {
        if (collateralToken == address(0) || signer == address(0)) revert ZeroAddress();
        if (signer.code.length == 0) revert InvalidSignerContract(signer);
        _collateralPolicies[collateralToken].signer = signer;
        emit SignerUpdated(collateralToken, signer);
    }

    /// @notice Set collateral-wide quote, duration, and reference freshness bounds.
    /// @param collateralToken Collateral contract governed by the policy.
    /// @param currencyToken Only currency token accepted for this collateral market.
    /// @param maxQuoteAge Maximum quote age in seconds.
    /// @param maxDuration Maximum signed quote duration in seconds.
    /// @param maxReferenceAge Maximum reference-price age in seconds.
    function setCollateralPolicy(
        address collateralToken,
        address currencyToken,
        uint64 maxQuoteAge,
        uint64 maxDuration,
        uint64 maxReferenceAge
    ) external onlyOwner {
        if (collateralToken == address(0) || currencyToken == address(0)) revert ZeroAddress();
        if (maxQuoteAge == 0 || maxDuration == 0 || maxReferenceAge == 0) {
            revert InvalidCollateralPolicy(collateralToken);
        }
        CollateralPolicy storage policy = _collateralPolicies[collateralToken];
        policy.currencyToken = currencyToken;
        policy.maxQuoteAge = maxQuoteAge;
        policy.maxDuration = maxDuration;
        policy.maxReferenceAge = maxReferenceAge;
        policy.configured = true;
        emit CollateralPolicyUpdated(collateralToken, currencyToken, maxQuoteAge, maxDuration, maxReferenceAge);
    }

    /// @notice Set token-level hard cap and reference-price policy.
    /// @param collateralToken Collateral contract containing the token.
    /// @param tokenId Token ID governed by the policy.
    /// @param maxPrice Hard maximum signed price for this token ID.
    /// @param referencePrice Governance reference price for deviation checks.
    /// @param referenceUpdatedAt Timestamp when the reference price was set.
    /// @param maxDeviationBps Maximum allowed deviation from the reference price.
    function setTokenPolicy(
        address collateralToken,
        uint256 tokenId,
        uint256 maxPrice,
        uint256 referencePrice,
        uint64 referenceUpdatedAt,
        uint16 maxDeviationBps
    ) external onlyOwner {
        if (collateralToken == address(0)) revert ZeroAddress();
        if (maxDeviationBps > BASIS_POINTS) revert InvalidDeviationBps(maxDeviationBps);
        uint256 currentTimestamp = block.timestamp;
        if (
            maxPrice == 0 || referencePrice == 0 || referencePrice > maxPrice || referenceUpdatedAt == 0
                || referenceUpdatedAt > currentTimestamp
        ) {
            revert InvalidTokenPolicy(collateralToken, tokenId);
        }
        _tokenPolicies[collateralToken][tokenId] =
            TokenPolicy(maxPrice, referencePrice, referenceUpdatedAt, maxDeviationBps, true);
        emit TokenPolicyUpdated(collateralToken, tokenId, maxPrice, referencePrice, referenceUpdatedAt, maxDeviationBps);
    }

    /// @notice Enable or disable a collateral market.
    /// @dev Enabling validates every supplied live tokenId so launch cannot proceed half-configured.
    /// @param collateralToken Collateral contract governed by the switch.
    /// @param enabled True to enable pricing, false to fail closed.
    /// @param liveTokenIds Complete token ID set that must be configured before enabling.
    function setCollateralEnabled(address collateralToken, bool enabled, uint256[] calldata liveTokenIds)
        external
        onlyOwner
    {
        if (collateralToken == address(0)) revert ZeroAddress();
        if (enabled) _validateCollateralReady(collateralToken, liveTokenIds);
        _collateralPolicies[collateralToken].enabled = enabled;
        emit CollateralEnabledUpdated(collateralToken, enabled);
    }

    /// @inheritdoc IPriceOracle
    function price(
        address collateralToken,
        address currencyToken,
        uint256[] memory collateralTokenIds,
        uint256[] memory collateralTokenQuantities,
        bytes calldata oracleContext
    ) external view override returns (uint256) {
        SignedQuote[] memory signedQuotes = abi.decode(oracleContext, (SignedQuote[]));
        if (signedQuotes.length == 0 || signedQuotes.length != collateralTokenIds.length) revert InvalidLength();
        if (collateralTokenIds.length != collateralTokenQuantities.length) revert InvalidLength();
        CollateralPolicy memory policy = _requireEnabledCollateral(collateralToken);
        if (policy.currencyToken != currencyToken) {
            revert InvalidCurrencyToken(collateralToken, policy.currencyToken, currencyToken);
        }
        uint256 totalOraclePrice = 0;
        uint256 totalQuantity = 0;
        for (uint256 i; i < collateralTokenIds.length; i++) {
            uint256 quantity = collateralTokenQuantities[i];
            if (quantity == 0) revert ZeroQuantity(i);
            uint256 quotePrice =
                _verifyQuote(collateralToken, collateralTokenIds[i], currencyToken, signedQuotes[i], policy);
            totalOraclePrice += quotePrice * quantity;
            totalQuantity += quantity;
        }
        return totalOraclePrice / totalQuantity;
    }

    /// @dev Owner/Safe-only UUPS upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Disable ownership renounce so oracle policy and upgrade recovery remain available.
    function renounceOwnership() public override onlyOwner {
        revert OwnershipRenounceDisabled();
    }

    function _requireEnabledCollateral(address collateralToken) private view returns (CollateralPolicy memory policy) {
        policy = _collateralPolicies[collateralToken];
        if (!policy.configured || policy.signer == address(0) || policy.currencyToken == address(0)) {
            revert MissingCollateralConfig(collateralToken);
        }
        if (!policy.enabled) revert MarketDisabled(collateralToken);
    }

    function _validateCollateralReady(address collateralToken, uint256[] calldata liveTokenIds) private view {
        CollateralPolicy memory policy = _collateralPolicies[collateralToken];
        if (!policy.configured || policy.signer == address(0) || policy.currencyToken == address(0)) {
            revert MissingCollateralConfig(collateralToken);
        }
        if (liveTokenIds.length == 0) revert TokenIdsRequired(collateralToken);
        for (uint256 i; i < liveTokenIds.length; i++) {
            TokenPolicy memory tokenPolicy_ = _tokenPolicies[collateralToken][liveTokenIds[i]];
            if (!tokenPolicy_.configured) revert MissingTokenConfig(collateralToken, liveTokenIds[i]);
            _validateReferenceFresh(liveTokenIds[i], tokenPolicy_, policy.maxReferenceAge);
        }
    }

    function _verifyQuote(
        address collateralToken,
        uint256 collateralTokenId,
        address currencyToken,
        SignedQuote memory signedQuote,
        CollateralPolicy memory policy
    ) private view returns (uint256) {
        Quote memory quote = signedQuote.quote;
        if (quote.token != collateralToken || quote.tokenId != collateralTokenId || quote.currency != currencyToken) {
            revert QuoteTokenMismatch(collateralToken, collateralTokenId, currencyToken);
        }
        if (quote.price == 0) revert QuotePriceZero(collateralTokenId);
        if (quote.duration > policy.maxDuration) revert QuoteDurationTooLong(quote.duration, policy.maxDuration);
        _validateQuoteFresh(quote.timestamp, quote.duration, policy.maxQuoteAge);
        if (!SignatureChecker.isValidSignatureNow(policy.signer, _quoteDigest(quote), signedQuote.signature)) {
            revert InvalidSigner(collateralToken, policy.signer);
        }
        TokenPolicy memory tokenPolicy_ = _tokenPolicies[collateralToken][collateralTokenId];
        if (!tokenPolicy_.configured) revert MissingTokenConfig(collateralToken, collateralTokenId);
        _validateCapAndReference(collateralTokenId, quote.price, tokenPolicy_, policy.maxReferenceAge);
        return quote.price;
    }

    function _quoteDigest(Quote memory quote) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE_TYPEHASH,
                    quote.token,
                    quote.tokenId,
                    quote.currency,
                    quote.price,
                    quote.timestamp,
                    quote.duration
                )
            )
        );
    }

    function _validateQuoteFresh(uint64 timestamp, uint64 duration, uint64 maxQuoteAge) private view {
        uint256 currentTimestamp = block.timestamp;
        if (timestamp > currentTimestamp) revert QuoteStale(timestamp, maxQuoteAge, currentTimestamp);
        if (currentTimestamp - timestamp > maxQuoteAge) revert QuoteStale(timestamp, maxQuoteAge, currentTimestamp);
        if (uint256(timestamp) + duration < currentTimestamp) {
            revert QuoteStale(timestamp, maxQuoteAge, currentTimestamp);
        }
    }

    function _validateCapAndReference(
        uint256 tokenId,
        uint256 quotePrice,
        TokenPolicy memory tokenPolicy_,
        uint64 maxReferenceAge
    ) private view {
        if (quotePrice > tokenPolicy_.maxPrice) {
            revert QuotePriceExceedsCap(tokenId, quotePrice, tokenPolicy_.maxPrice);
        }
        _validateReferenceFresh(tokenId, tokenPolicy_, maxReferenceAge);
        uint256 delta = quotePrice > tokenPolicy_.referencePrice
            ? quotePrice - tokenPolicy_.referencePrice
            : tokenPolicy_.referencePrice - quotePrice;
        uint256 allowedDelta = Math.mulDiv(tokenPolicy_.referencePrice, tokenPolicy_.maxDeviationBps, BASIS_POINTS);
        if (delta > allowedDelta) {
            revert QuoteDeviationTooHigh(tokenId, quotePrice, tokenPolicy_.referencePrice, tokenPolicy_.maxDeviationBps);
        }
    }

    function _validateReferenceFresh(uint256 tokenId, TokenPolicy memory tokenPolicy_, uint64 maxReferenceAge)
        private
        view
    {
        uint256 currentTimestamp = block.timestamp;
        if (
            tokenPolicy_.referenceUpdatedAt > currentTimestamp
                || currentTimestamp - tokenPolicy_.referenceUpdatedAt > maxReferenceAge
        ) {
            revert ReferencePriceStale(tokenId, tokenPolicy_.referenceUpdatedAt, maxReferenceAge);
        }
    }
}
