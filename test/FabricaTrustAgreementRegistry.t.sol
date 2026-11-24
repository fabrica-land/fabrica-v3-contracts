// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FabricaTrustAgreementRegistry} from "../src/FabricaTrustAgreementRegistry.sol";
import {FabricaTrustAgreementRegistryDeployScript} from "../script/FabricaTrustAgreementRegistryDeploy.s.sol";
import {FabricaTrustAgreementRegistryLoadScript} from "../script/FabricaTrustAgreementRegistryLoad.s.sol";
import {TrustAgreementFixtures} from "./fixtures/TrustAgreementFixtures.sol";

contract AgreementTokenFixture {
    mapping(uint256 => string) public agreement;

    function setAgreement(uint256 id, string calldata uri) external {
        agreement[id] = uri;
    }

    function _property(uint256 id)
        external
        view
        returns (uint256, string memory, string memory, string memory, address)
    {
        return (1, agreement[id], "", "", address(0));
    }
}

contract FabricaTrustAgreementRegistryTest is TrustAgreementFixtures {
    AgreementTokenFixture internal token;
    FabricaTrustAgreementRegistry internal registry;

    function setUp() public {
        token = new AgreementTokenFixture();
        registry = new FabricaTrustAgreementRegistry(address(token));
    }

    function _checkReal(uint256 index) internal {
        string memory uri = _uris()[index];
        bytes memory data = _fixture(uri);
        address[] memory chunks = _stage(registry, data);
        registry.store(uri, chunks);
        assertEq(bytes(registry.text(uri)), data);
        (bytes32 contentHash, uint256 length, address[] memory storedChunks) = registry.agreement(uri);
        assertEq(contentHash, sha256(data));
        assertEq(length, data.length);
        assertEq(storedChunks, chunks);
        for (uint256 i; i < chunks.length; ++i) {
            assertTrue(registry.isChunk(chunks[i]));
            assertLe(chunks[i].code.length, 24001);
            assertEq(chunks[i].code[0], bytes1(0));
        }
        token.setAgreement(42, uri);
        assertEq(bytes(registry.textForToken(42)), data);
    }

    function testRealV31() public {
        _checkReal(0);
    }

    function testRealV32() public {
        _checkReal(1);
    }

    function testRealV34() public {
        _checkReal(2);
    }

    function testRealV33() public {
        _checkReal(3);
    }

    function testRealV44() public {
        _checkReal(4);
    }

    function testRealV43() public {
        _checkReal(5);
    }

    function testRealV42() public {
        _checkReal(6);
    }

    function testRejectsInvalidTokenContract() public {
        vm.expectRevert(FabricaTrustAgreementRegistry.InvalidTokenContract.selector);
        new FabricaTrustAgreementRegistry(address(0));
        vm.expectRevert(FabricaTrustAgreementRegistry.InvalidTokenContract.selector);
        new FabricaTrustAgreementRegistry(address(123));
    }

    function testMissingAgreementAndTokenRevert() public {
        vm.expectRevert(
            abi.encodeWithSelector(FabricaTrustAgreementRegistry.AgreementNotStored.selector, "ipfs://missing")
        );
        registry.text("ipfs://missing");
        vm.expectRevert(abi.encodeWithSelector(FabricaTrustAgreementRegistry.AgreementNotStored.selector, ""));
        registry.textForToken(999);
        (bytes32 contentHash, uint256 length, address[] memory chunks) = registry.agreement("ipfs://missing");
        assertEq(contentHash, bytes32(0));
        assertEq(length, 0);
        assertEq(chunks.length, 0);
    }

    function testRejectsEmptyAndOversizeChunks() public {
        vm.expectRevert(abi.encodeWithSelector(FabricaTrustAgreementRegistry.InvalidChunkLength.selector, 0));
        registry.writeChunk("");
        vm.expectRevert(abi.encodeWithSelector(FabricaTrustAgreementRegistry.InvalidChunkLength.selector, 24001));
        registry.writeChunk(new bytes(24001));
    }

    function testRejectsUnrecognizedChunk() public {
        address[] memory chunks = new address[](1);
        chunks[0] = address(token);
        vm.expectRevert(abi.encodeWithSelector(FabricaTrustAgreementRegistry.InvalidChunk.selector, address(token)));
        registry.store(_uris()[0], chunks);
    }

    function testRejectsEmptyAndOversizeAgreements() public {
        vm.expectRevert(abi.encodeWithSelector(FabricaTrustAgreementRegistry.InvalidTextLength.selector, 0));
        registry.store(_uris()[0], new address[](0));
        address part = registry.writeChunk(new bytes(24000));
        address[] memory chunks = new address[](11);
        for (uint256 i; i < chunks.length; ++i) {
            chunks[i] = part;
        }
        vm.expectRevert(abi.encodeWithSelector(FabricaTrustAgreementRegistry.InvalidTextLength.selector, 264000));
        registry.store(_uris()[0], chunks);
    }

    function testDuplicateCannotOverwriteEvenFromAnotherCaller() public {
        string memory uri = _uris()[0];
        bytes memory data = _fixture(uri);
        address[] memory chunks = _stage(registry, data);
        vm.prank(address(0xBEEF));
        registry.store(uri, chunks);
        vm.prank(address(0xCAFE));
        vm.expectRevert(abi.encodeWithSelector(FabricaTrustAgreementRegistry.AgreementAlreadyStored.selector, uri));
        registry.store(uri, new address[](0));
        assertEq(bytes(registry.text(uri)), data);
    }

    function testWrongBytesCannotPoisonAUri() public {
        string memory uri = _uris()[0];
        address[] memory wrong = _stage(registry, bytes("wrong"));
        vm.expectRevert(FabricaTrustAgreementRegistry.ContentAddressMismatch.selector);
        registry.store(uri, wrong);
        (, uint256 length,) = registry.agreement(uri);
        assertEq(length, 0);
        registry.store(uri, _stage(registry, _fixture(uri)));
        assertEq(bytes(registry.text(uri)), _fixture(uri));
    }

    function testWrongOrderAndNoncanonicalUrisRevert() public {
        string memory uri = _uris()[4];
        address[] memory chunks = _stage(registry, _fixture(uri));
        (chunks[0], chunks[1]) = (chunks[1], chunks[0]);
        vm.expectRevert(FabricaTrustAgreementRegistry.ContentAddressMismatch.selector);
        registry.store(uri, chunks);
        vm.expectRevert(FabricaTrustAgreementRegistry.ContentAddressMismatch.selector);
        registry.store(string.concat(uri, "/file.txt"), chunks);
        vm.expectRevert(FabricaTrustAgreementRegistry.ContentAddressMismatch.selector);
        registry.store("https://gateway.invalid/ipfs/file", chunks);
    }

    function testCidV1DagPb() public {
        bytes memory data = _fixture(_uris()[0]);
        string memory uri = "ipfs://bafybeieg6gdzywmaky5vtb7jeg4nffvasyuqgs4rp64x6te54m3e5qy6me";
        registry.store(uri, _stage(registry, data));
        assertEq(bytes(registry.text(uri)), data);
    }

    function testBinaryUtf8AndWhitespacePreserved() public {
        bytes memory data = hex"00ff0a0d0a68656c6c6f20e29883200a";
        string memory uri = "ipfs://bafkreih7zyjj5c7heyv7cp465hhqmkhr7a3xmsj24gpaktfyjvoho4uoqq";
        registry.store(uri, _stage(registry, data));
        assertEq(bytes(registry.text(uri)), data);
    }

    function _checkBoundary(uint256 length, string memory uri) internal {
        bytes memory data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = "a";
        }
        address[] memory chunks = _stage(registry, data);
        registry.store(uri, chunks);
        assertEq(bytes(registry.text(uri)), data);
    }

    function testBoundary1() public {
        _checkBoundary(1, "ipfs://bafkreigks6arfsq3xxfpvqrrwonchxcnu6do76auprhhfomao6c273sixm");
    }

    function testBoundary31() public {
        _checkBoundary(31, "ipfs://bafkreidbyyfuq7i2sipaxte37bj53ih3cwntbp2xwlrnfr2twaf6cw22be");
    }

    function testBoundary32() public {
        _checkBoundary(32, "ipfs://bafkreib3up27io4smatihqm25zrkea2cwccn2wlr3xjtqcgydiziq6nfi4");
    }

    function testBoundary23999() public {
        _checkBoundary(23999, "ipfs://bafkreibisny23l2a2d64nze44g3qn3kh4ghh2d5y6e7o7awrwwn6qixfdq");
    }

    function testBoundary24000() public {
        _checkBoundary(24000, "ipfs://bafkreiark5gs33psy3plptkveanmhpp6hhpgmmhrievrnmphw6v5fiaiza");
    }

    function testBoundary24001() public {
        _checkBoundary(24001, "ipfs://bafkreihawjazwdl7oynyebupiitp3ohuy62tukfonads6pgnl4bl7yp67u");
    }

    function testBoundary262144() public {
        _checkBoundary(262144, "ipfs://bafkreig5hxpioyr5tjvtktdizfb5dcoitrrwklmulz5334eynsxjdjevee");
    }

    function testDeployAndLoadScripts() public {
        FabricaTrustAgreementRegistryDeployScript deploy = new FabricaTrustAgreementRegistryDeployScript();
        FabricaTrustAgreementRegistry fresh = deploy.run(address(token));
        assertEq(address(fresh.token()), address(token));
        FabricaTrustAgreementRegistryLoadScript loader = new FabricaTrustAgreementRegistryLoadScript();
        string memory uri = _uris()[4];
        loader.run(
            address(fresh),
            uri,
            "test/fixtures/operating-agreements/bafkreih72odii5wcwluejt67is5q4zgdqiwqabzkg4pr5vys6o77pgujw4.txt"
        );
        assertEq(bytes(fresh.text(uri)), _fixture(uri));
    }
}
