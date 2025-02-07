// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook} from "../interfaces/IHook.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";

/// @title ZkProofHook
/// @notice Enhanced ZK proof hook with refund support and improved security
/// @dev Implements IHook with beforeFund, beforeRelease, and beforeRefund
contract ZkProofHook is IHook {
    // ============================================
    // ERRORS
    // ============================================

    error ProofNotSubmitted();
    error InvalidProof();
    error ProofAlreadySubmitted();
    error NotAuthorized();
    error ZeroAddress();
    error ProofExpired();

    // ============================================
    // EVENTS
    // ============================================

    event ProofSubmitted(
        address indexed by,
        bytes32 indexed publicInputHash,
        uint256 timestamp,
        uint256 expiresAt
    );
    event ProofVerified(address indexed verifier, bool success, uint256 timestamp);
    event ProofInvalidated(address indexed by, uint256 timestamp);

    // ============================================
    // STATE VARIABLES
    // ============================================

    IVerifier public immutable verifier;
    bytes32 public immutable expectedPublicInputHash;
    address public immutable escrow;
    address public immutable operator; // Can submit proofs

    bytes public submittedProof;
    bool public proofSubmitted;
    uint256 public proofSubmittedAt;
    uint256 public proofExpiresAt;

    // Configuration
    bool public requireProofForFund;
    bool public requireProofForRelease;
    bool public requireProofForRefund;
    uint256 public proofValidityPeriod; // 0 = no expiry

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Initialize ZK proof hook
    /// @param _verifier Address of the ZK verifier contract
    /// @param _expectedPublicInputHash Expected public input hash for proofs
    /// @param _escrow Address of the escrow contract using this hook
    /// @param _operator Address authorized to submit proofs
    /// @param _requireProofForRelease Whether to require proof for release
    /// @param _proofValidityPeriod How long proofs remain valid (0 = forever)
    constructor(
        address _verifier,
        bytes32 _expectedPublicInputHash,
        address _escrow,
        address _operator,
        bool _requireProofForRelease,
        uint256 _proofValidityPeriod
    ) {
        if (_verifier == address(0) || _escrow == address(0)) revert ZeroAddress();

        verifier = IVerifier(_verifier);
        expectedPublicInputHash = _expectedPublicInputHash;
        escrow = _escrow;
        operator = _operator;
        requireProofForRelease = _requireProofForRelease;
        proofValidityPeriod = _proofValidityPeriod;

        // Default: don't require proof for fund/refund
        requireProofForFund = false;
        requireProofForRefund = false;
    }

    // ============================================
    // MAIN FUNCTIONS
    // ============================================

    /// @notice Submit a ZK proof for verification
    /// @param proof The proof bytes
    function submitProof(bytes calldata proof) external {
        if (msg.sender != operator && msg.sender != escrow) revert NotAuthorized();
        if (proofSubmitted) revert ProofAlreadySubmitted();

        // Verify the proof immediately
        bool isValid = verifier.verify(proof, expectedPublicInputHash);
        if (!isValid) revert InvalidProof();

        submittedProof = proof;
        proofSubmitted = true;
        proofSubmittedAt = block.timestamp;

        if (proofValidityPeriod > 0) {
            proofExpiresAt = block.timestamp + proofValidityPeriod;
        }

        emit ProofSubmitted(msg.sender, expectedPublicInputHash, block.timestamp, proofExpiresAt);
        emit ProofVerified(address(verifier), true, block.timestamp);
    }

    /// @notice Invalidate the current proof (operator only)
    function invalidateProof() external {
        if (msg.sender != operator) revert NotAuthorized();

        proofSubmitted = false;
        delete submittedProof;
        proofSubmittedAt = 0;
        proofExpiresAt = 0;

        emit ProofInvalidated(msg.sender, block.timestamp);
    }

    // ============================================
    // HOOK FUNCTIONS
    // ============================================

    /// @notice Hook called before funding
    function beforeFund(address /*from*/, uint256 /*amount*/) external view override {
        if (!requireProofForFund) return;
        _checkProof();
    }

    /// @notice Hook called before release
    function beforeRelease(address /*to*/) external view override {
        if (!requireProofForRelease) return;
        _checkProof();
    }

    /// @notice Hook called before refund
    function beforeRefund(address /*to*/) external view override {
        if (!requireProofForRefund) return;
        _checkProof();
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _checkProof() internal view {
        if (!proofSubmitted) revert ProofNotSubmitted();

        // Check if proof has expired
        if (proofExpiresAt > 0 && block.timestamp > proofExpiresAt) {
            revert ProofExpired();
        }

        // Re-verify the proof
        bool ok = verifier.verify(submittedProof, expectedPublicInputHash);
        if (!ok) revert InvalidProof();
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Check if a valid proof is currently available
    function hasValidProof() external view returns (bool) {
        if (!proofSubmitted) return false;
        if (proofExpiresAt > 0 && block.timestamp > proofExpiresAt) return false;

        return verifier.verify(submittedProof, expectedPublicInputHash);
    }

    /// @notice Get time remaining until proof expires
    function timeUntilExpiry() external view returns (uint256) {
        if (!proofSubmitted || proofExpiresAt == 0) return 0;
        if (block.timestamp >= proofExpiresAt) return 0;
        return proofExpiresAt - block.timestamp;
    }
}
