// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook} from "../interfaces/IHook.sol";

/// @notice Minimal Ownable (no OZ dependency).
abstract contract OwnableLite {
    error NotOwner();
    error ZeroAddress();

    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
        emit OwnershipTransferred(msg.sender, newOwner);
    }
}

/// @title AllowlistHook
/// @notice Enhanced allowlist hook with refund support and batch operations
/// @dev Implements IHook with symmetric lifecycle coverage
contract AllowlistHook is IHook, OwnableLite {
    mapping(address => bool) public allowed;

    event AllowedSet(address indexed who, bool allowed);

    constructor(address _owner) OwnableLite(_owner) {}

    function setAllowed(address who, bool isAllowed) external onlyOwner {
        allowed[who] = isAllowed;
        emit AllowedSet(who, isAllowed);
    }

    /// @notice Batch set allowlist status for multiple addresses (gas efficient)
    /// @param addresses Array of addresses to update
    /// @param isAllowed Whether to allow or disallow these addresses
    function setAllowedBatch(address[] calldata addresses, bool isAllowed) external onlyOwner {
        for (uint256 i = 0; i < addresses.length; i++) {
            allowed[addresses[i]] = isAllowed;
            emit AllowedSet(addresses[i], isAllowed);
        }
    }

    function beforeFund(address from, uint256 /*amount*/) external view override {
        require(allowed[from], "ALLOWLIST: funder not allowed");
    }

    function beforeRelease(address to) external view override {
        require(allowed[to], "ALLOWLIST: beneficiary not allowed");
    }

    function beforeRefund(address to) external view override {
        require(allowed[to], "ALLOWLIST: refund recipient not allowed");
    }
}
