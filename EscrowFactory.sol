// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Escrow} from "./Escrow.sol";

/// @title EscrowFactory
/// @notice Factory for deterministic escrow deployment using CREATE2
/// @dev Enables predictable addresses and centralized escrow tracking
contract EscrowFactory {
    // ============================================
    // EVENTS
    // ============================================

    event EscrowCreated(
        address indexed escrow,
        address indexed payer,
        address indexed beneficiary,
        address arbiter,
        address token,
        uint256 amount,
        address hook,
        uint256 deadline,
        bytes32 salt
    );

    event FactoryPaused(address indexed by, uint256 timestamp);
    event FactoryUnpaused(address indexed by, uint256 timestamp);

    // ============================================
    // ERRORS
    // ============================================

    error FactoryPaused();
    error NotOwner();
    error ZeroAddress();

    // ============================================
    // STATE VARIABLES
    // ============================================

    address public owner;
    bool public paused;

    // Track all created escrows
    address[] public allEscrows;
    mapping(address => address[]) public escrowsByPayer;
    mapping(address => address[]) public escrowsByBeneficiary;

    // Statistics
    uint256 public totalEscrowsCreated;
    uint256 public totalValueLocked; // ETH only for simplicity

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert FactoryPaused();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor() {
        owner = msg.sender;
        paused = false;
    }

    // ============================================
    // MAIN FUNCTIONS
    // ============================================

    /// @notice Create a new escrow with CREATE2 for deterministic address
    /// @param payer Address funding the escrow
    /// @param beneficiary Address receiving funds on release
    /// @param arbiter Address authorized to release/refund (can be address(0))
    /// @param token Token address (address(0) for ETH)
    /// @param amount Escrow amount
    /// @param hook Hook contract address (address(0) for no hook)
    /// @param deadline Deadline for automatic refund (0 for no deadline)
    /// @param salt Unique salt for CREATE2
    /// @return escrow Address of created escrow
    function createEscrow(
        address payer,
        address beneficiary,
        address arbiter,
        address token,
        uint256 amount,
        address hook,
        uint256 deadline,
        bytes32 salt
    ) external whenNotPaused returns (address escrow) {
        // Deploy with CREATE2
        bytes memory bytecode = abi.encodePacked(
            type(Escrow).creationCode,
            abi.encode(payer, beneficiary, arbiter, token, amount, hook, deadline)
        );

        assembly {
            escrow := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
            if iszero(escrow) {
                revert(0, 0)
            }
        }

        // Track escrow
        allEscrows.push(escrow);
        escrowsByPayer[payer].push(escrow);
        escrowsByBeneficiary[beneficiary].push(escrow);

        totalEscrowsCreated++;
        if (token == address(0)) {
            totalValueLocked += amount;
        }

        emit EscrowCreated(
            escrow,
            payer,
            beneficiary,
            arbiter,
            token,
            amount,
            hook,
            deadline,
            salt
        );

        return escrow;
    }

    /// @notice Predict escrow address before deployment
    /// @param payer Address funding the escrow
    /// @param beneficiary Address receiving funds on release
    /// @param arbiter Address authorized to release/refund
    /// @param token Token address (address(0) for ETH)
    /// @param amount Escrow amount
    /// @param hook Hook contract address
    /// @param deadline Deadline timestamp
    /// @param salt Unique salt for CREATE2
    /// @return predicted Predicted escrow address
    function predictEscrowAddress(
        address payer,
        address beneficiary,
        address arbiter,
        address token,
        uint256 amount,
        address hook,
        uint256 deadline,
        bytes32 salt
    ) external view returns (address predicted) {
        bytes memory bytecode = abi.encodePacked(
            type(Escrow).creationCode,
            abi.encode(payer, beneficiary, arbiter, token, amount, hook, deadline)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );

        return address(uint160(uint256(hash)));
    }

    /// @notice Generate a unique salt based on parameters
    /// @param payer Payer address
    /// @param beneficiary Beneficiary address
    /// @param nonce User-provided nonce for uniqueness
    /// @return Generated salt
    function generateSalt(
        address payer,
        address beneficiary,
        uint256 nonce
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(payer, beneficiary, nonce));
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Pause factory (prevents new escrow creation)
    function pauseFactory() external onlyOwner {
        paused = true;
        emit FactoryPaused(msg.sender, block.timestamp);
    }

    /// @notice Unpause factory
    function unpauseFactory() external onlyOwner {
        paused = false;
        emit FactoryUnpaused(msg.sender, block.timestamp);
    }

    /// @notice Transfer ownership
    /// @param newOwner New owner address
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Get all escrows created by this factory
    function getAllEscrows() external view returns (address[] memory) {
        return allEscrows;
    }

    /// @notice Get escrows by payer
    /// @param payer Payer address
    function getEscrowsByPayer(address payer) external view returns (address[] memory) {
        return escrowsByPayer[payer];
    }

    /// @notice Get escrows by beneficiary
    /// @param beneficiary Beneficiary address
    function getEscrowsByBeneficiary(address beneficiary) external view returns (address[] memory) {
        return escrowsByBeneficiary[beneficiary];
    }

    /// @notice Get total number of escrows created
    function getEscrowCount() external view returns (uint256) {
        return allEscrows.length;
    }
}
