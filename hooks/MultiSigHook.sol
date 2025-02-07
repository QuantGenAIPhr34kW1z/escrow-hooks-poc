// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook} from "../interfaces/IHook.sol";

/// @title MultiSigHook
/// @notice Hook requiring M-of-N signatures for escrow actions
/// @dev Implements multi-signature approval pattern for enhanced security
contract MultiSigHook is IHook {
    // ============================================
    // ENUMS
    // ============================================

    enum Action {
        Fund,
        Release,
        Refund
    }

    // ============================================
    // STRUCTS
    // ============================================

    struct Approval {
        uint256 count;
        mapping(address => bool) approved;
        uint256 expiresAt;
    }

    // ============================================
    // ERRORS
    // ============================================

    error InsufficientApprovals(uint256 current, uint256 required);
    error NotSigner();
    error AlreadyApproved();
    error ApprovalExpired();
    error InvalidThreshold();
    error InvalidSigners();
    error ZeroAddress();

    // ============================================
    // EVENTS
    // ============================================

    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdChanged(Action action, uint256 oldThreshold, uint256 newThreshold);
    event Approved(Action indexed action, address indexed signer, uint256 count, uint256 required);
    event ApprovalRevoked(Action indexed action, address indexed signer);
    event ApprovalsReset(Action indexed action);

    // ============================================
    // STATE VARIABLES
    // ============================================

    address[] public signers;
    mapping(address => bool) public isSigner;

    uint256 public fundThreshold;
    uint256 public releaseThreshold;
    uint256 public refundThreshold;

    uint256 public approvalValidityPeriod; // How long approvals last (0 = forever)

    // action => approval data
    mapping(Action => Approval) private approvals;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Initialize multi-sig hook
    /// @param _signers Array of signer addresses
    /// @param _fundThreshold Number of approvals required for fund
    /// @param _releaseThreshold Number of approvals required for release
    /// @param _refundThreshold Number of approvals required for refund
    /// @param _approvalValidityPeriod How long approvals remain valid (0 = forever)
    constructor(
        address[] memory _signers,
        uint256 _fundThreshold,
        uint256 _releaseThreshold,
        uint256 _refundThreshold,
        uint256 _approvalValidityPeriod
    ) {
        if (_signers.length == 0) revert InvalidSigners();
        if (_fundThreshold == 0 || _fundThreshold > _signers.length) revert InvalidThreshold();
        if (_releaseThreshold == 0 || _releaseThreshold > _signers.length) revert InvalidThreshold();
        if (_refundThreshold == 0 || _refundThreshold > _signers.length) revert InvalidThreshold();

        for (uint256 i = 0; i < _signers.length; i++) {
            address signer = _signers[i];
            if (signer == address(0)) revert ZeroAddress();
            if (isSigner[signer]) continue; // Skip duplicates

            signers.push(signer);
            isSigner[signer] = true;
            emit SignerAdded(signer);
        }

        fundThreshold = _fundThreshold;
        releaseThreshold = _releaseThreshold;
        refundThreshold = _refundThreshold;
        approvalValidityPeriod = _approvalValidityPeriod;
    }

    // ============================================
    // APPROVAL FUNCTIONS
    // ============================================

    /// @notice Approve funding action
    function approveFund() external {
        _approve(Action.Fund, fundThreshold);
    }

    /// @notice Approve release action
    function approveRelease() external {
        _approve(Action.Release, releaseThreshold);
    }

    /// @notice Approve refund action
    function approveRefund() external {
        _approve(Action.Refund, refundThreshold);
    }

    /// @notice Revoke approval for an action
    /// @param action The action to revoke approval for
    function revokeApproval(Action action) external {
        if (!isSigner[msg.sender]) revert NotSigner();

        Approval storage approval = approvals[action];
        if (!approval.approved[msg.sender]) return;

        approval.approved[msg.sender] = false;
        approval.count--;

        emit ApprovalRevoked(action, msg.sender);
    }

    /// @notice Reset all approvals for an action
    /// @param action The action to reset
    function resetApprovals(Action action) external {
        if (!isSigner[msg.sender]) revert NotSigner();

        Approval storage approval = approvals[action];
        approval.count = 0;
        approval.expiresAt = 0;

        // Clear all approvals
        for (uint256 i = 0; i < signers.length; i++) {
            approval.approved[signers[i]] = false;
        }

        emit ApprovalsReset(action);
    }

    // ============================================
    // HOOK FUNCTIONS
    // ============================================

    function beforeFund(address /*from*/, uint256 /*amount*/) external view override {
        _checkApprovals(Action.Fund, fundThreshold);
    }

    function beforeRelease(address /*to*/) external view override {
        _checkApprovals(Action.Release, releaseThreshold);
    }

    function beforeRefund(address /*to*/) external view override {
        _checkApprovals(Action.Refund, refundThreshold);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _approve(Action action, uint256 threshold) internal {
        if (!isSigner[msg.sender]) revert NotSigner();

        Approval storage approval = approvals[action];

        // Check if approval has expired
        if (approval.expiresAt > 0 && block.timestamp > approval.expiresAt) {
            // Reset expired approvals
            approval.count = 0;
            for (uint256 i = 0; i < signers.length; i++) {
                approval.approved[signers[i]] = false;
            }
        }

        if (approval.approved[msg.sender]) revert AlreadyApproved();

        approval.approved[msg.sender] = true;
        approval.count++;

        if (approvalValidityPeriod > 0 && approval.expiresAt == 0) {
            approval.expiresAt = block.timestamp + approvalValidityPeriod;
        }

        emit Approved(action, msg.sender, approval.count, threshold);
    }

    function _checkApprovals(Action action, uint256 threshold) internal view {
        Approval storage approval = approvals[action];

        // Check if approvals have expired
        if (approval.expiresAt > 0 && block.timestamp > approval.expiresAt) {
            revert ApprovalExpired();
        }

        if (approval.count < threshold) {
            revert InsufficientApprovals(approval.count, threshold);
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Get approval count for an action
    function getApprovalCount(Action action) external view returns (uint256) {
        return approvals[action].count;
    }

    /// @notice Check if address has approved an action
    function hasApproved(Action action, address signer) external view returns (bool) {
        return approvals[action].approved[signer];
    }

    /// @notice Check if action has enough approvals
    function hasEnoughApprovals(Action action) external view returns (bool) {
        uint256 threshold;
        if (action == Action.Fund) threshold = fundThreshold;
        else if (action == Action.Release) threshold = releaseThreshold;
        else threshold = refundThreshold;

        Approval storage approval = approvals[action];

        if (approval.expiresAt > 0 && block.timestamp > approval.expiresAt) {
            return false;
        }

        return approval.count >= threshold;
    }

    /// @notice Get time until approvals expire
    function timeUntilExpiry(Action action) external view returns (uint256) {
        uint256 expiresAt = approvals[action].expiresAt;
        if (expiresAt == 0) return 0;
        if (block.timestamp >= expiresAt) return 0;
        return expiresAt - block.timestamp;
    }

    /// @notice Get all signers
    function getSigners() external view returns (address[] memory) {
        return signers;
    }

    /// @notice Get signer count
    function getSignerCount() external view returns (uint256) {
        return signers.length;
    }

    /// @notice Get approval progress for an action
    /// @return count Current approval count
    /// @return required Required approval count
    /// @return expiresAt When approvals expire (0 = never)
    function getApprovalProgress(Action action)
        external
        view
        returns (uint256 count, uint256 required, uint256 expiresAt)
    {
        Approval storage approval = approvals[action];

        if (action == Action.Fund) required = fundThreshold;
        else if (action == Action.Release) required = releaseThreshold;
        else required = refundThreshold;

        return (approval.count, required, approval.expiresAt);
    }
}
