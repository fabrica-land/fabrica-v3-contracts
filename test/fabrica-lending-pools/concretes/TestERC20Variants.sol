// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * Two non-standard ERC20s used exclusively to exercise the `Pool.repay`
 * branches that the standard TestERC20 cannot:
 *
 *   - TestERC20ReturnsFalse: transferFrom returns `false` (instead of
 *     reverting) on insufficient allowance. Exercises branch E — the
 *     `require(transferFrom(...))` in Pool.repay must catch the false
 *     and revert.
 *   - TestERC20NoReturnValue: transferFrom has no return value (USDT-
 *     style). Exercises branch F — Solidity 0.8+ strict ABI decoder
 *     must revert on the empty returndata, leaving the borrower's
 *     loan untouched (safe-fail, not silent success).
 *
 * Both intentionally do NOT inherit from TestERC20 — they implement
 * just the surface Pool.repay touches, with the specific quirk we
 * want to test.
 */

contract TestERC20ReturnsFalse {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// Returns false (instead of reverting) when the caller is unauthorized.
    /// Pool.repay's `require(transferFrom(...))` must catch this and revert.
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) {
            return false;
        }
        if (balanceOf[from] < amount) {
            return false;
        }
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract TestERC20NoReturnValue {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    /// USDT-style: no return value. Pool.repay's `require(IERC20.transferFrom(...))`
    /// expects a bool; strict ABI decoder reverts on empty returndata.
    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
