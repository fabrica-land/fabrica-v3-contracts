// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FabricaTrustAgreementRegistry} from "../src/FabricaTrustAgreementRegistry.sol";
import {IFabricaToken} from "../src/IFabricaToken.sol";
import {IFabricaValidator} from "../src/IFabricaValidator.sol";
import {TrustAgreementFixtures} from "./fixtures/TrustAgreementFixtures.sol";

contract FabricaTrustAgreementRegistryMainnetForkTest is TrustAgreementFixtures {
    address internal constant PROPERTY_CONTRACT = 0x5cbeb7A0df7Ed85D82a472FD56d81ed550f3Ea95;
    address internal constant VALIDATOR = 0x170511f95560A1F280c29026f73a9cD6a4bA8ab0;
    FabricaTrustAgreementRegistry internal registry;

    function setUp() public {
        if (bytes(vm.envOr("MAINNET_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("mainnet", 26_482_359);
        registry = new FabricaTrustAgreementRegistry(PROPERTY_CONTRACT);
    }

    function _stateHash(uint256 tokenId, string memory uri) internal view returns (bytes32) {
        (bool success, bytes memory property) =
            PROPERTY_CONTRACT.staticcall(abi.encodeCall(IFabricaToken._property, (tokenId)));
        require(success, "property read failed");
        return keccak256(
            abi.encode(
                property,
                PROPERTY_CONTRACT.codehash,
                VALIDATOR.codehash,
                IFabricaValidator(VALIDATOR).defaultOperatingAgreement(),
                IFabricaValidator(VALIDATOR).operatingAgreementName(uri)
            )
        );
    }

    function _checkVersion(uint256 index, uint256 tokenId, string memory expectedName) internal {
        string memory uri = _uris()[index];
        {
            (uint256 supply, string memory pointer,,,) = IFabricaToken(PROPERTY_CONTRACT)._property(tokenId);
            assertGt(supply, 0);
            assertEq(pointer, uri);
        }
        assertEq(IFabricaValidator(VALIDATOR).operatingAgreementName(uri), expectedName);
        bytes32 stateBefore = _stateHash(tokenId, uri);
        bytes memory data = _fixture(uri);
        registry.store(uri, _stage(registry, data));
        assertEq(bytes(registry.text(uri)), data);
        assertEq(bytes(registry.textForToken(tokenId)), data);
        (bytes32 digest, uint256 length,) = registry.agreement(uri);
        assertEq(digest, sha256(data));
        assertEq(length, data.length);
        assertEq(_stateHash(tokenId, uri), stateBefore);
    }

    function testForkVersion0() public {
        _checkVersion(0, 216358582526726280, "Fabrica US Trust v3.1");
    }

    function testForkVersion1() public {
        _checkVersion(1, 18174272903809786939, "Fabrica US Trust v3.2");
    }

    function testForkVersion2() public {
        _checkVersion(2, 706575488147908729, "Fabrica US Trust v3.4");
    }

    function testForkVersion3() public {
        _checkVersion(3, 2297880476626253769, "Fabrica US Trust v3.3");
    }

    function testForkVersion4() public {
        _checkVersion(4, 791778799614624646, "Fabrica US Trust v4.4");
    }

    function testForkVersion5() public {
        _checkVersion(5, 3775392155688387140, "Fabrica US Trust v4.3");
    }

    function testForkVersion6() public {
        _checkVersion(6, 11888523710004325986, "Fabrica US Trust v4.2");
    }
}
