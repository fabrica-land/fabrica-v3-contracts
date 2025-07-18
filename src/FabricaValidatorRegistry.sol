// SPDX-License-Identifier: MIT

pragma solidity ^0.8.28;

import {Address} from "../lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {ERC165Checker} from "../lib/openzeppelin-contracts/contracts/utils/introspection/ERC165Checker.sol";
import {IERC165} from "../lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {OwnableUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {Initializable} from "../lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import {ERC165Upgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/utils/introspection/ERC165Upgradeable.sol";
import {ContextUpgradeable} from "../lib/openzeppelin-contracts-upgradeable/contracts/utils/ContextUpgradeable.sol";
import {FabricaUUPSUpgradeable} from "./FabricaUUPSUpgradeable.sol";
import {IFabricaValidatorRegistry} from "./IFabricaValidatorRegistry.sol";

contract FabricaValidatorRegistry is IFabricaValidatorRegistry, Initializable, IERC165, ERC165Upgradeable, OwnableUpgradeable, FabricaUUPSUpgradeable {
    using Address for address;

    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __ERC165_init();
        __FabricaUUPSUpgradeable_init();
        __Ownable_init(_msgSender());
    }

    mapping(address => string) private _names;

    event ValidatorNameUpdated(address addr, string name);

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function addName(address addr, string memory name_) public onlyOwner {
        require(bytes(_names[addr]).length < 1, "Validator name record for addr already exists");
        require(bytes(name_).length > 0, "name_ is required");
        _names[addr] = name_;
        emit ValidatorNameUpdated(addr, name_);
    }

    function removeName(address addr) public onlyOwner {
        require(bytes(_names[addr]).length > 0, "Validator name record for addr does not exist");
        delete _names[addr];
        emit ValidatorNameUpdated(addr, "");
    }

    function updateName(address addr, string memory name_) public onlyOwner {
        require(bytes(_names[addr]).length > 0, "Validator name record for addr does not exist");
        require(bytes(name_).length > 0, "Use removeValidatorName");
        _names[addr] = name_;
        emit ValidatorNameUpdated(addr, name_);
    }

    function name(address addr) public view returns (string memory) {
        return _names[addr];
    }
}
