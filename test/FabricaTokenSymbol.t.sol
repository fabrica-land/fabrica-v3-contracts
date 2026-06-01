// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";
import {FabricaProxy} from "../src/FabricaProxy.sol";

/// @dev Minimal mirror of the EIP-721 Metadata `symbol()` getter. This is the
/// exact interface MetaStreet's lending-pool deposit token uses to read a
/// collateral collection's symbol — `IERC721Metadata(collateralToken).symbol()`
/// in src/fabrica-lending-pools/tokenization/ERC20DepositTokenImplementation.sol.
/// Declared locally because the OZ v5 tree vendored for Fabrica's own contracts
/// does not ship the ERC721 metadata interface (it lives in the OZ v4 tree that
/// is remap-scoped to the vendored MetaStreet sources only).
interface IErc721MetadataSymbol {
    function symbol() external view returns (string memory);
}

/// @notice Verifies the Fabrica 1155 token exposes a collection symbol of
/// "FABRICA" through the EIP-721 Metadata `symbol()` getter, the path MetaStreet
/// integrates against (ENG-3226).
contract FabricaTokenSymbolTest is Test {
    /// @dev Canonical EIP-721 Metadata `symbol()` selector.
    bytes4 internal constant SYMBOL_SELECTOR = 0x95d89b41;

    FabricaToken public token;
    address public proxyAdmin;

    function setUp() public {
        proxyAdmin = address(0xAD);
        FabricaToken impl = new FabricaToken();
        bytes memory initData = abi.encodeCall(FabricaToken.initialize, ());
        FabricaProxy proxy = new FabricaProxy(address(impl), proxyAdmin, initData);
        token = FabricaToken(address(proxy));
    }

    function test_symbol_returnsFabrica() public view {
        assertEq(token.symbol(), "FABRICA", "symbol should be FABRICA");
    }

    /// @dev The getter MUST be reachable through the EIP-721 Metadata interface,
    /// since that is how MetaStreet's deposit token reads the collateral symbol.
    function test_symbol_readableViaErc721MetadataInterface() public view {
        assertEq(
            IErc721MetadataSymbol(address(token)).symbol(), "FABRICA", "symbol via IERC721Metadata should be FABRICA"
        );
    }

    /// @dev Exposing the bare symbol() getter must NOT make the token advertise
    /// the full EIP-721 Metadata interface (id 0x5b5e139f) via ERC-165. This is
    /// an ERC-1155, not an ERC-721; falsely claiming IERC721Metadata conformance
    /// would mislead generic NFT tooling into using the ERC-721 transfer ABI /
    /// ownerOf assumptions. MetaStreet reads symbol() by selector with no ERC-165
    /// probe, so the bare getter is sufficient. This locks the decision in.
    function test_symbol_doesNotAdvertiseErc721MetadataInterface() public view {
        bytes4 erc721MetadataInterfaceId = 0x5b5e139f;
        assertFalse(
            token.supportsInterface(erc721MetadataInterfaceId),
            "must NOT claim ERC721Metadata conformance: contract is ERC-1155"
        );
    }

    /// @dev Lock the ABI: the getter must answer on the well-known EIP-721
    /// Metadata `symbol()` selector so interface-agnostic callers reach it.
    function test_symbol_usesErc721MetadataSelector() public pure {
        assertEq(FabricaToken.symbol.selector, SYMBOL_SELECTOR, "selector must match EIP-721 symbol()");
        assertEq(bytes4(keccak256("symbol()")), SYMBOL_SELECTOR, "EIP-721 symbol() selector sanity");
    }

    /// @dev A raw staticcall (what an off-chain indexer or a contract holding
    /// only the selector would do) must succeed and decode to FABRICA.
    function test_symbol_viaRawStaticcall() public view {
        (bool ok, bytes memory ret) = address(token).staticcall(abi.encodeWithSelector(SYMBOL_SELECTOR));
        assertTrue(ok, "staticcall to symbol() should succeed");
        assertEq(abi.decode(ret, (string)), "FABRICA", "raw staticcall should decode to FABRICA");
    }

    /// @dev The symbol getter must not be coupled to pause state — MetaStreet and
    /// other metadata consumers may read it while the collection is paused. The
    /// getter is `pure` so it cannot observe pause state; this locks that in.
    function test_symbol_readableWhilePaused() public {
        token.pause();
        assertTrue(token.paused(), "precondition: token should be paused");
        assertEq(token.symbol(), "FABRICA", "symbol must be readable while paused");
    }

    /// @dev The symbol is a compiled constant with no backing storage, so it must
    /// survive a UUPS upgrade. This exercises the empty-data upgrade path used for
    /// the Sepolia rollout (the canonical proxy is already at reinitializer
    /// version 5, so no initializer runs during the symbol upgrade).
    function test_symbol_persistsAcrossUpgrade() public {
        assertEq(token.symbol(), "FABRICA", "symbol before upgrade");
        FabricaToken newImpl = new FabricaToken();
        vm.prank(proxyAdmin);
        token.upgradeToAndCall(address(newImpl), "");
        assertEq(token.symbol(), "FABRICA", "symbol after upgrade");
    }
}
