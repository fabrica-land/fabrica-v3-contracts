// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test helper: the Merkle tree an oracle writer anchors over one cycle's token ids.
/// @dev Leaf is `keccak256(abi.encode(tokenId))` and internal nodes use sorted-pair hashing,
///      matching `BenchAggregatorBase._provenUnderRoot`. A cycle covering 1,000 tokens gives a
///      proof of depth 10, which is the shape Tim's 18:17Z rule costs the aggregator.
library MerkleCycle {
    /// @notice Build the full tree over `tokenIds`, padded to a power of two by repeating the last leaf.
    function build(uint256[] memory tokenIds) internal pure returns (bytes32[][] memory levels) {
        uint256 n = 1;
        while (n < tokenIds.length) {
            n <<= 1;
        }
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            leaves[i] = keccak256(abi.encode(i < tokenIds.length ? tokenIds[i] : tokenIds[tokenIds.length - 1]));
        }
        uint256 depth;
        for (uint256 m = n; m > 1; m >>= 1) {
            ++depth;
        }
        levels = new bytes32[][](depth + 1);
        levels[0] = leaves;
        for (uint256 d; d < depth; ++d) {
            bytes32[] memory cur = levels[d];
            bytes32[] memory next = new bytes32[](cur.length / 2);
            for (uint256 i; i < next.length; ++i) {
                bytes32 a = cur[2 * i];
                bytes32 b = cur[2 * i + 1];
                next[i] = a <= b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
            }
            levels[d + 1] = next;
        }
    }

    function root(bytes32[][] memory levels) internal pure returns (bytes32) {
        return levels[levels.length - 1][0];
    }

    function proof(bytes32[][] memory levels, uint256 index) internal pure returns (bytes32[] memory path) {
        path = new bytes32[](levels.length - 1);
        uint256 idx = index;
        for (uint256 d; d < levels.length - 1; ++d) {
            path[d] = levels[d][idx ^ 1];
            idx >>= 1;
        }
    }
}
