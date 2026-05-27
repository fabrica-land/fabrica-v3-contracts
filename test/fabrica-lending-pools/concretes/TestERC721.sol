// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * Minimal ERC721 for borrow/repay tests. Implements just enough of the
 * standard for Pool._transferCollateral (transferFrom) — owner tracking,
 * single-address approvals, and operator approvals.
 */
contract TestERC721 {
    string public name;
    string public symbol;

    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 tokenId) external {
        require(to != address(0), "zero to");
        require(ownerOf[tokenId] == address(0), "minted");
        ownerOf[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        return _tokenApprovals[tokenId];
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf[tokenId];
        require(msg.sender == owner || isApprovedForAll[owner][msg.sender], "not owner");
        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(to != address(0), "zero to");
        address owner = ownerOf[tokenId];
        require(owner == from, "wrong from");
        require(
            msg.sender == owner || msg.sender == _tokenApprovals[tokenId] || isApprovedForAll[owner][msg.sender],
            "not authorized"
        );
        delete _tokenApprovals[tokenId];
        ownerOf[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }
}
