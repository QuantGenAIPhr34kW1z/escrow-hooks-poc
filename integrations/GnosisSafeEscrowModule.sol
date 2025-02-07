// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Escrow} from "../Escrow.sol";
import {EscrowFactory} from "../EscrowFactory.sol";

/// @notice Minimal Gnosis Safe interface
interface IGnosisSafe {
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation
    ) external returns (bool success);

    function isOwner(address owner) external view returns (bool);
    function getOwners() external view returns (address[] memory);
}

/// @title GnosisSafeEscrowModule
/// @notice Gnosis Safe module for managing multiple escrows from a Safe
/// @dev Allows Safes to create and manage escrows as arbiter or payer
contract GnosisSafeEscrowModule {
    // ============================================
    // EVENTS
    // ============================================

    event EscrowCreatedViaSafe(
        address indexed safe,
        address indexed escrow,
        address beneficiary,
        uint256 amount
    );

    event EscrowReleasedViaSafe(
        address indexed safe,
        address indexed escrow,
        uint256 amount
    );

    event EscrowRefundedViaSafe(
        address indexed safe,
        address indexed escrow,
        uint256 amount
    );

    // ============================================
    // ERRORS
    // ============================================

    error NotSafeOwner();
    error ModuleExecutionFailed();
    error ZeroAddress();

    // ============================================
    // STATE VARIABLES
    // ============================================

    EscrowFactory public immutable factory;

    // Track escrows created by each Safe
    mapping(address => address[]) public escrowsBySafe;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(address _factory) {
        if (_factory == address(0)) revert ZeroAddress();
        factory = EscrowFactory(_factory);
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlySafeOwner(address safe) {
        if (!IGnosisSafe(safe).isOwner(msg.sender)) revert NotSafeOwner();
        _;
    }

    // ============================================
    // MAIN FUNCTIONS
    // ============================================

    /// @notice Create escrow via Safe as payer
    /// @param safe Gnosis Safe address (will be payer)
    /// @param beneficiary Beneficiary address
    /// @param arbiter Arbiter address (can be Safe or another address)
    /// @param token Token address (address(0) for ETH)
    /// @param amount Escrow amount
    /// @param hook Hook address
    /// @param deadline Deadline timestamp
    /// @param salt CREATE2 salt
    function createEscrowAsPayer(
        address safe,
        address beneficiary,
        address arbiter,
        address token,
        uint256 amount,
        address hook,
        uint256 deadline,
        bytes32 salt
    ) external onlySafeOwner(safe) returns (address escrow) {
        // Create escrow via factory
        escrow = factory.createEscrow(
            safe,           // Safe is payer
            beneficiary,
            arbiter,
            token,
            amount,
            hook,
            deadline,
            salt
        );

        escrowsBySafe[safe].push(escrow);

        emit EscrowCreatedViaSafe(safe, escrow, beneficiary, amount);

        return escrow;
    }

    /// @notice Release escrow via Safe (when Safe is arbiter or payer)
    /// @param safe Gnosis Safe address
    /// @param escrow Escrow address to release
    function releaseEscrow(
        address safe,
        address escrow
    ) external onlySafeOwner(safe) returns (bool) {
        // Execute release via Safe's execTransactionFromModule
        bytes memory data = abi.encodeWithSelector(Escrow.release.selector);

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            escrow,
            0,
            data,
            0 // CALL operation
        );

        if (!success) revert ModuleExecutionFailed();

        Escrow escrowContract = Escrow(payable(escrow));
        emit EscrowReleasedViaSafe(safe, escrow, escrowContract.amount());

        return true;
    }

    /// @notice Partial release via Safe
    /// @param safe Gnosis Safe address
    /// @param escrow Escrow address
    /// @param releaseAmount Amount to release
    function partialReleaseEscrow(
        address safe,
        address escrow,
        uint256 releaseAmount
    ) external onlySafeOwner(safe) returns (bool) {
        bytes memory data = abi.encodeWithSelector(
            Escrow.partialRelease.selector,
            releaseAmount
        );

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            escrow,
            0,
            data,
            0 // CALL operation
        );

        if (!success) revert ModuleExecutionFailed();

        emit EscrowReleasedViaSafe(safe, escrow, releaseAmount);

        return true;
    }

    /// @notice Refund escrow via Safe
    /// @param safe Gnosis Safe address
    /// @param escrow Escrow address to refund
    function refundEscrow(
        address safe,
        address escrow
    ) external onlySafeOwner(safe) returns (bool) {
        bytes memory data = abi.encodeWithSelector(Escrow.refund.selector);

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            escrow,
            0,
            data,
            0 // CALL operation
        );

        if (!success) revert ModuleExecutionFailed();

        Escrow escrowContract = Escrow(payable(escrow));
        uint256 remaining = escrowContract.amount() - escrowContract.releasedAmount();

        emit EscrowRefundedViaSafe(safe, escrow, remaining);

        return true;
    }

    /// @notice Fund escrow via Safe
    /// @param safe Gnosis Safe address
    /// @param escrow Escrow address to fund
    /// @param value ETH value to send (if ETH escrow)
    function fundEscrow(
        address safe,
        address escrow,
        uint256 value
    ) external onlySafeOwner(safe) returns (bool) {
        bytes memory data = abi.encodeWithSelector(Escrow.fund.selector);

        bool success = IGnosisSafe(safe).execTransactionFromModule(
            escrow,
            value,
            data,
            0 // CALL operation
        );

        if (!success) revert ModuleExecutionFailed();

        return true;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Get all escrows created by a Safe
    /// @param safe Safe address
    function getEscrowsBySafe(address safe) external view returns (address[] memory) {
        return escrowsBySafe[safe];
    }

    /// @notice Get escrow count for a Safe
    /// @param safe Safe address
    function getEscrowCount(address safe) external view returns (uint256) {
        return escrowsBySafe[safe].length;
    }
}
