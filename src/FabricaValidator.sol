// SPDX-License-Identifier: MIT
// Validator smart contract for Fabrica version 1.0

pragma solidity ^0.8.21;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {FabricaUUPSUpgradeable} from "./FabricaUUPSUpgradeable.sol";
import {IFabricaValidator} from "./IFabricaValidator.sol";

/**
 * @dev Implementation of the Fabrica validator smart contract
 *      Delegates the metadata `uri` function to this contract
 *      May add other fields in newer versions
 */
contract FabricaValidator is IFabricaValidator, Initializable, FabricaUUPSUpgradeable, OwnableUpgradeable {
    using Address for address;

    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(_msgSender());
        __UUPSUpgradeable_init();
    }

    string private _baseUri;
    mapping(string => string) private _operatingAgreementNames;
    string private _defaultOperatingAgreement;

    event OperatingAgreementNameUpdated(string uri, string name);
    event DefaultOperatingAgreementUpdated(string uri);

    /**
     * @dev One-time storage repair for validator proxies that were upgraded OZ v4 -> v5 without
     * migrating their original linear-layout storage.
     *
     * Under OZ v4 the base contracts consumed ~200 linear slots via `__gap` arrays, so the first
     * custom variable `_baseUri` lived at slot 201. Under OZ v5 the bases use ERC-7201 namespaced
     * storage (zero linear slots), so `_baseUri` is now slot 0 — which still holds the leftover v4
     * `Initializable._initialized = 1`. That is an invalid string length encoding, so `uri()` /
     * `baseUri()` revert with Panic 0x22, and `_baseUri` cannot be repaired with a normal assignment
     * (assigning over it decodes the corrupt length and panics).
     *
     * `_defaultOperatingAgreement` and newer `_operatingAgreementNames` self-healed because they were
     * re-written after the v5 upgrade (so they sit at the v5 slots and read fine); only `_baseUri`
     * was never re-written, and operating-agreement names added before the v5 upgrade are stranded
     * at the old v4 mapping slot. This reinitializer therefore: (1) wipes the corrupt `_baseUri` slot
     * and sets the correct value, and (2) re-stores the stranded operating-agreement names. It keeps
     * the v5 layout (no `__legacy_gap`) so the live v5-era data is preserved. Identical code runs on
     * every network; per-network values are passed as arguments and applied atomically inside
     * `upgradeToAndCall`.
     */
    function initializeV2(
        string calldata baseUri_,
        string[] calldata strandedOperatingAgreementUris,
        string[] calldata strandedOperatingAgreementNames
    ) external onlyProxyAdmin reinitializer(2) {
        require(
            strandedOperatingAgreementUris.length == strandedOperatingAgreementNames.length,
            "uris/names length mismatch"
        );
        // A normal `_baseUri = ...` assignment first decodes the existing (corrupt) value to free its
        // storage and panics 0x22, so clear the slot directly before assigning.
        assembly {
            sstore(_baseUri.slot, 0)
        }
        _baseUri = baseUri_;
        for (uint256 i = 0; i < strandedOperatingAgreementUris.length; i++) {
            _operatingAgreementNames[strandedOperatingAgreementUris[i]] = strandedOperatingAgreementNames[i];
            emit OperatingAgreementNameUpdated(
                strandedOperatingAgreementUris[i], strandedOperatingAgreementNames[i]
            );
        }
    }

    function setDefaultOperatingAgreement(string memory uri_) public onlyOwner {
        _defaultOperatingAgreement = uri_;
        emit DefaultOperatingAgreementUpdated(uri_);
    }

    function defaultOperatingAgreement() public view returns (string memory) {
        return _defaultOperatingAgreement;
    }

    function addOperatingAgreementName(string memory uri_, string memory name) public onlyOwner {
        require(
            bytes(_operatingAgreementNames[uri_]).length < 1, "Operating Agreement name record for uri_ already exists"
        );
        require(bytes(name).length > 0, "name is required");
        _operatingAgreementNames[uri_] = name;
        emit OperatingAgreementNameUpdated(uri_, name);
    }

    function removeOperatingAgreementName(string memory uri_) public onlyOwner {
        require(
            bytes(_operatingAgreementNames[uri_]).length > 0, "Operating Agreement name record for uri_ does not exist"
        );
        delete _operatingAgreementNames[uri_];
        emit OperatingAgreementNameUpdated(uri_, "");
    }

    function updateOperatingAgreementName(string memory uri_, string memory name) public onlyOwner {
        require(
            bytes(_operatingAgreementNames[uri_]).length > 0, "Operating Agreement name record for uri_ does not exist"
        );
        require(bytes(name).length > 0, "Use removeOperatingAgreementName");
        _operatingAgreementNames[uri_] = name;
        emit OperatingAgreementNameUpdated(uri_, name);
    }

    function operatingAgreementName(string memory uri_) public view returns (string memory) {
        return _operatingAgreementNames[uri_];
    }

    function setBaseUri(string memory newBaseUri) public onlyOwner {
        _baseUri = newBaseUri;
    }

    function baseUri() public view returns (string memory) {
        return _baseUri;
    }

    function uri(uint256 id) public view returns (string memory) {
        return string.concat(_baseUri, Strings.toString(id));
    }
}
