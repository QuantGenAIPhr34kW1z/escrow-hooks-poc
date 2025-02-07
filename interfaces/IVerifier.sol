// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal verifier interface intended to match common "proof + public input" patterns.
/// This is intentionally generic (design-focused), not crypto-opinionated.
interface IVerifier {
    function verify(bytes calldata proof, bytes32 publicInputHash) external view returns (bool);
}


