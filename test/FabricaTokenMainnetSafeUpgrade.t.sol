// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FabricaToken} from "../src/FabricaToken.sol";

/// @notice ENG-3145 mainnet Safe-upgrade dry run. Forks Ethereum mainnet and executes the EXACT
/// calldata the 2-of-3 Safe (`0x769586A6…07Fb0`, proxyAdmin == owner) will approve, against the
/// REAL proxy (`0x5cbeb7A0…3Ea95`) and the REAL deployed implementation (`0xF8b3…730b`),
/// impersonating the Safe. Proves the V4 -> V5 -> V6 ceremony lands the new impl, migrates the
/// owner, bumps the version to 6, and leaves the burn-remint guard active — WITHOUT executing
/// anything on-chain. CLAUDE.md "Shipping a live contract change" step 6.
///
/// Run: forge test --match-contract FabricaTokenMainnetSafeUpgradeTest --fork-url $MAINNET_RPC_URL -vvv
contract FabricaTokenMainnetSafeUpgradeTest is Test {
    address constant PROXY = 0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95;
    address constant SAFE = 0x769586A65825B028b005176F1ebbd3B82bB07Fb0; // proxyAdmin == owner
    address constant NEW_IMPL = 0xF8b3429F4a85F844C7A1d56F9443de299c20730b;
    address constant OLD_IMPL = 0x7c26B9e463554b2FD348eafAB33A5928Fdba3a73;
    bytes32 constant INIT_SLOT = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
    uint256 constant FORK_BLOCK = 25_238_609;

    // The EXACT calldata each Safe transaction carries (target = PROXY, value = 0).
    // tx1: upgradeToAndCall(NEW_IMPL, abi.encodeCall(initializeV4, ()))
    bytes constant TX1_UPGRADE_V4 =
        hex"4f1ef286000000000000000000000000f8b3429f4a85f844c7a1d56f9443de299c20730b0000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000454a0860600000000000000000000000000000000000000000000000000000000";
    bytes constant TX2_V5 = hex"16e1f015"; // initializeV5()
    bytes constant TX3_V6 = hex"a10e57a8"; // initializeV6()

    FabricaToken token;

    modifier onlyFork() {
        if (PROXY.code.length == 0) return; // not running with --fork-url; skip silently
        _;
    }

    function setUp() public {
        if (PROXY.code.length > 0) {
            vm.rollFork(FORK_BLOCK);
        }
        token = FabricaToken(PROXY);
    }

    function _version() internal view returns (uint256) {
        return uint256(vm.load(PROXY, INIT_SLOT)) & 0xff;
    }

    function test_mainnet_safeUpgrade_exactCalldata_V4_V5_V6() public onlyFork {
        // --- preconditions (live mainnet state) ---
        assertEq(token.proxyAdmin(), SAFE, "precondition: proxyAdmin is the Safe");
        assertEq(token.owner(), SAFE, "precondition: owner is the Safe (v4 reads legacy slot 101)");
        assertEq(token.implementation(), OLD_IMPL, "precondition: still on the old v4 impl");
        assertEq(_version(), 0, "precondition: ERC-7201 _initialized is 0 on the v4 impl");

        // --- execute the EXACT three Safe transactions, in order, as the Safe ---
        vm.startPrank(SAFE);
        (bool ok1,) = PROXY.call(TX1_UPGRADE_V4);
        require(ok1, "tx1 upgradeToAndCall(NEW_IMPL, initializeV4) reverted");
        (bool ok2,) = PROXY.call(TX2_V5);
        require(ok2, "tx2 initializeV5() reverted");
        (bool ok3,) = PROXY.call(TX3_V6);
        require(ok3, "tx3 initializeV6() reverted");
        vm.stopPrank();

        // --- end state ---
        assertEq(token.implementation(), NEW_IMPL, "impl must be the new definition-guard build");
        assertEq(token.owner(), SAFE, "owner migrated to the Safe via initializeV4");
        assertEq(token.proxyAdmin(), SAFE, "proxyAdmin still the Safe");
        assertEq(_version(), 6, "version bumped to 6");
        assertEq(token.symbol(), "FABRICA", "symbol() present on the new build");

        // --- burn-remint guard is active on the upgraded mainnet proxy ---
        address minter = makeAddr("mainnet-fork-minter");
        if (minter.code.length > 0) vm.etch(minter, "");
        address[] memory r = new address[](1);
        r[0] = minter;
        uint256[] memory a = new uint256[](1);
        a[0] = 3;
        vm.prank(minter);
        uint256 id =
            token.mint(r, 918_273, a, "ipfs://eng3145-mainnet-fork", "ipfs://oa-mainnet-fork", "{}", address(0));
        vm.prank(minter);
        token.burn(minter, id, 3);
        vm.prank(minter);
        vm.expectRevert("Session ID already exist, please use a different one");
        token.mint(r, 918_273, a, "ipfs://EVIL", "ipfs://oa-mainnet-fork", "{}", address(0));
    }

    /// @dev The exact upgrade calldata must be admin-gated: a non-Safe caller cannot run it.
    function test_mainnet_nonSafe_cannotRunUpgradeCalldata() public onlyFork {
        vm.prank(address(0xBEEF));
        (bool ok,) = PROXY.call(TX1_UPGRADE_V4);
        assertFalse(ok, "non-admin upgradeToAndCall must revert");
        assertEq(token.implementation(), OLD_IMPL, "impl unchanged after rejected non-admin call");
    }
}
