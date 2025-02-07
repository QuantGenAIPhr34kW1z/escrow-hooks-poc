// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook} from "../interfaces/IHook.sol";

/// @title TimeLockedHook
/// @notice Hook that enforces time-based conditions on escrow actions
/// @dev Allows setting time windows for fund, release, and refund operations
contract TimeLockedHook is IHook {
    // ============================================
    // STRUCTS
    // ============================================

    struct TimeLock {
        uint256 notBefore; // Cannot execute before this time (0 = no restriction)
        uint256 notAfter;  // Cannot execute after this time (0 = no restriction)
        bool enabled;
    }

    // ============================================
    // ERRORS
    // ============================================

    error TooEarly(uint256 currentTime, uint256 notBefore);
    error TooLate(uint256 currentTime, uint256 notAfter);
    error TimeLockNotEnabled();
    error InvalidTimeWindow();
    error NotOwner();
    error ZeroAddress();

    // ============================================
    // EVENTS
    // ============================================

    event TimeLockSet(
        string action,
        uint256 notBefore,
        uint256 notAfter,
        bool enabled
    );
    event TimeLockChecked(
        string action,
        uint256 timestamp,
        bool passed
    );
    event EmergencyOverrideEnabled(address indexed by, uint256 timestamp);
    event EmergencyOverrideDisabled(address indexed by, uint256 timestamp);

    // ============================================
    // STATE VARIABLES
    // ============================================

    address public owner;

    TimeLock public fundTimeLock;
    TimeLock public releaseTimeLock;
    TimeLock public refundTimeLock;

    bool public emergencyOverride; // Owner can bypass time locks in emergency

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
    }

    // ============================================
    // CONFIGURATION FUNCTIONS
    // ============================================

    /// @notice Set time lock for funding
    /// @param notBefore Cannot fund before this timestamp
    /// @param notAfter Cannot fund after this timestamp
    function setFundTimeLock(uint256 notBefore, uint256 notAfter) external onlyOwner {
        if (notAfter > 0 && notBefore >= notAfter) revert InvalidTimeWindow();

        fundTimeLock = TimeLock({
            notBefore: notBefore,
            notAfter: notAfter,
            enabled: true
        });

        emit TimeLockSet("fund", notBefore, notAfter, true);
    }

    /// @notice Set time lock for release
    /// @param notBefore Cannot release before this timestamp
    /// @param notAfter Cannot release after this timestamp
    function setReleaseTimeLock(uint256 notBefore, uint256 notAfter) external onlyOwner {
        if (notAfter > 0 && notBefore >= notAfter) revert InvalidTimeWindow();

        releaseTimeLock = TimeLock({
            notBefore: notBefore,
            notAfter: notAfter,
            enabled: true
        });

        emit TimeLockSet("release", notBefore, notAfter, true);
    }

    /// @notice Set time lock for refund
    /// @param notBefore Cannot refund before this timestamp
    /// @param notAfter Cannot refund after this timestamp
    function setRefundTimeLock(uint256 notBefore, uint256 notAfter) external onlyOwner {
        if (notAfter > 0 && notBefore >= notAfter) revert InvalidTimeWindow();

        refundTimeLock = TimeLock({
            notBefore: notBefore,
            notAfter: notAfter,
            enabled: true
        });

        emit TimeLockSet("refund", notBefore, notAfter, true);
    }

    /// @notice Disable fund time lock
    function disableFundTimeLock() external onlyOwner {
        fundTimeLock.enabled = false;
        emit TimeLockSet("fund", 0, 0, false);
    }

    /// @notice Disable release time lock
    function disableReleaseTimeLock() external onlyOwner {
        releaseTimeLock.enabled = false;
        emit TimeLockSet("release", 0, 0, false);
    }

    /// @notice Disable refund time lock
    function disableRefundTimeLock() external onlyOwner {
        refundTimeLock.enabled = false;
        emit TimeLockSet("refund", 0, 0, false);
    }

    /// @notice Enable emergency override (bypasses all time locks)
    function enableEmergencyOverride() external onlyOwner {
        emergencyOverride = true;
        emit EmergencyOverrideEnabled(msg.sender, block.timestamp);
    }

    /// @notice Disable emergency override
    function disableEmergencyOverride() external onlyOwner {
        emergencyOverride = false;
        emit EmergencyOverrideDisabled(msg.sender, block.timestamp);
    }

    // ============================================
    // HOOK FUNCTIONS
    // ============================================

    function beforeFund(address /*from*/, uint256 /*amount*/) external view override {
        if (emergencyOverride) return;
        if (!fundTimeLock.enabled) return;

        _checkTimeLock(fundTimeLock, "fund");
    }

    function beforeRelease(address /*to*/) external view override {
        if (emergencyOverride) return;
        if (!releaseTimeLock.enabled) return;

        _checkTimeLock(releaseTimeLock, "release");
    }

    function beforeRefund(address /*to*/) external view override {
        if (emergencyOverride) return;
        if (!refundTimeLock.enabled) return;

        _checkTimeLock(refundTimeLock, "refund");
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _checkTimeLock(TimeLock memory lock, string memory action) internal view {
        uint256 currentTime = block.timestamp;

        // Check notBefore
        if (lock.notBefore > 0 && currentTime < lock.notBefore) {
            revert TooEarly(currentTime, lock.notBefore);
        }

        // Check notAfter
        if (lock.notAfter > 0 && currentTime > lock.notAfter) {
            revert TooLate(currentTime, lock.notAfter);
        }

        emit TimeLockChecked(action, currentTime, true);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Check if funding is currently allowed
    function canFundNow() external view returns (bool) {
        if (emergencyOverride) return true;
        if (!fundTimeLock.enabled) return true;

        uint256 currentTime = block.timestamp;
        if (fundTimeLock.notBefore > 0 && currentTime < fundTimeLock.notBefore) return false;
        if (fundTimeLock.notAfter > 0 && currentTime > fundTimeLock.notAfter) return false;

        return true;
    }

    /// @notice Check if release is currently allowed
    function canReleaseNow() external view returns (bool) {
        if (emergencyOverride) return true;
        if (!releaseTimeLock.enabled) return true;

        uint256 currentTime = block.timestamp;
        if (releaseTimeLock.notBefore > 0 && currentTime < releaseTimeLock.notBefore) return false;
        if (releaseTimeLock.notAfter > 0 && currentTime > releaseTimeLock.notAfter) return false;

        return true;
    }

    /// @notice Check if refund is currently allowed
    function canRefundNow() external view returns (bool) {
        if (emergencyOverride) return true;
        if (!refundTimeLock.enabled) return true;

        uint256 currentTime = block.timestamp;
        if (refundTimeLock.notBefore > 0 && currentTime < refundTimeLock.notBefore) return false;
        if (refundTimeLock.notAfter > 0 && currentTime > refundTimeLock.notAfter) return false;

        return true;
    }

    /// @notice Get time until funding is allowed
    function timeUntilFundingAllowed() external view returns (uint256) {
        if (!fundTimeLock.enabled || fundTimeLock.notBefore == 0) return 0;
        if (block.timestamp >= fundTimeLock.notBefore) return 0;
        return fundTimeLock.notBefore - block.timestamp;
    }

    /// @notice Get time until release is allowed
    function timeUntilReleaseAllowed() external view returns (uint256) {
        if (!releaseTimeLock.enabled || releaseTimeLock.notBefore == 0) return 0;
        if (block.timestamp >= releaseTimeLock.notBefore) return 0;
        return releaseTimeLock.notBefore - block.timestamp;
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }
}
