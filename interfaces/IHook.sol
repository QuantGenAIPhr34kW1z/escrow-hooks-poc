// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Enhanced hook interface for escrow lifecycle events.
/// @dev Adds beforeRefund hook for symmetric lifecycle coverage.
///      Hooks enable composable extensions like compliance checks, ZK verification, etc.
///      Hooks may revert to block escrow actions.
interface IHook {
    /// @notice Called before funds are deposited into escrow
    /// @param from The address funding the escrow (typically the payer)
    /// @param amount The amount being funded
    function beforeFund(address from, uint256 amount) external;

    /// @notice Called before funds are released from escrow
    /// @param to The address receiving the funds (typically the beneficiary)
    function beforeRelease(address to) external;

    /// @notice Called before funds are refunded from escrow
    /// @param to The address receiving the refund (typically the payer)
    function beforeRefund(address to) external;
}
