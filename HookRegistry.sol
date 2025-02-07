// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title HookRegistry
/// @notice Registry of verified and audited hooks for the escrow system
/// @dev Enables discovery of trusted hooks and community-driven quality control
contract HookRegistry {
    // ============================================
    // STRUCTS
    // ============================================

    struct HookInfo {
        address hookAddress;
        string name;
        string description;
        address developer;
        uint256 registeredAt;
        bool verified;
        bool deprecated;
        string auditReport; // IPFS hash or URL
        uint256 usageCount;
        string version;
    }

    // ============================================
    // EVENTS
    // ============================================

    event HookRegistered(
        address indexed hookAddress,
        string name,
        address indexed developer,
        uint256 timestamp
    );
    event HookVerified(address indexed hookAddress, address indexed verifier, uint256 timestamp);
    event HookDeprecated(address indexed hookAddress, string reason, uint256 timestamp);
    event HookUsed(address indexed hookAddress, address indexed escrow);
    event VerifierAdded(address indexed verifier);
    event VerifierRemoved(address indexed verifier);

    // ============================================
    // ERRORS
    // ============================================

    error NotOwner();
    error NotVerifier();
    error HookAlreadyRegistered();
    error HookNotFound();
    error HookDeprecated();
    error ZeroAddress();

    // ============================================
    // STATE VARIABLES
    // ============================================

    address public owner;
    mapping(address => bool) public verifiers;

    // Hook storage
    mapping(address => HookInfo) public hooks;
    address[] public allHooks;

    // Categorization
    mapping(string => address[]) public hooksByCategory;
    mapping(address => string[]) public categoriesByHook;

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyVerifier() {
        if (!verifiers[msg.sender] && msg.sender != owner) revert NotVerifier();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor() {
        owner = msg.sender;
        verifiers[msg.sender] = true;
    }

    // ============================================
    // REGISTRATION FUNCTIONS
    // ============================================

    /// @notice Register a new hook
    /// @param hookAddress Address of the hook contract
    /// @param name Human-readable name
    /// @param description Detailed description
    /// @param auditReport IPFS hash or URL to audit report
    /// @param version Version string (e.g., "1.0.0")
    function registerHook(
        address hookAddress,
        string calldata name,
        string calldata description,
        string calldata auditReport,
        string calldata version
    ) external {
        if (hookAddress == address(0)) revert ZeroAddress();
        if (hooks[hookAddress].hookAddress != address(0)) revert HookAlreadyRegistered();

        hooks[hookAddress] = HookInfo({
            hookAddress: hookAddress,
            name: name,
            description: description,
            developer: msg.sender,
            registeredAt: block.timestamp,
            verified: false,
            deprecated: false,
            auditReport: auditReport,
            usageCount: 0,
            version: version
        });

        allHooks.push(hookAddress);

        emit HookRegistered(hookAddress, name, msg.sender, block.timestamp);
    }

    /// @notice Verify a hook (verifiers only)
    /// @param hookAddress Address of hook to verify
    function verifyHook(address hookAddress) external onlyVerifier {
        if (hooks[hookAddress].hookAddress == address(0)) revert HookNotFound();

        hooks[hookAddress].verified = true;

        emit HookVerified(hookAddress, msg.sender, block.timestamp);
    }

    /// @notice Deprecate a hook
    /// @param hookAddress Address of hook to deprecate
    /// @param reason Reason for deprecation
    function deprecateHook(address hookAddress, string calldata reason) external {
        if (hooks[hookAddress].hookAddress == address(0)) revert HookNotFound();
        if (msg.sender != hooks[hookAddress].developer && msg.sender != owner) {
            revert NotOwner();
        }

        hooks[hookAddress].deprecated = true;

        emit HookDeprecated(hookAddress, reason, block.timestamp);
    }

    /// @notice Add hook to category
    /// @param hookAddress Hook address
    /// @param category Category name (e.g., "compliance", "zk-proof", "oracle")
    function addToCategory(address hookAddress, string calldata category) external {
        if (hooks[hookAddress].hookAddress == address(0)) revert HookNotFound();
        if (msg.sender != hooks[hookAddress].developer && msg.sender != owner) {
            revert NotOwner();
        }

        hooksByCategory[category].push(hookAddress);
        categoriesByHook[hookAddress].push(category);
    }

    /// @notice Increment usage count when hook is used
    /// @param hookAddress Hook being used
    /// @param escrow Escrow using the hook
    function recordUsage(address hookAddress, address escrow) external {
        if (hooks[hookAddress].hookAddress == address(0)) revert HookNotFound();

        hooks[hookAddress].usageCount++;

        emit HookUsed(hookAddress, escrow);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    /// @notice Add verifier
    /// @param verifier Address to add as verifier
    function addVerifier(address verifier) external onlyOwner {
        if (verifier == address(0)) revert ZeroAddress();
        verifiers[verifier] = true;
        emit VerifierAdded(verifier);
    }

    /// @notice Remove verifier
    /// @param verifier Address to remove from verifiers
    function removeVerifier(address verifier) external onlyOwner {
        verifiers[verifier] = false;
        emit VerifierRemoved(verifier);
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

    /// @notice Get hook info
    /// @param hookAddress Hook address
    function getHookInfo(address hookAddress) external view returns (HookInfo memory) {
        return hooks[hookAddress];
    }

    /// @notice Get all hooks
    function getAllHooks() external view returns (address[] memory) {
        return allHooks;
    }

    /// @notice Get verified hooks only
    function getVerifiedHooks() external view returns (address[] memory) {
        uint256 verifiedCount = 0;
        for (uint256 i = 0; i < allHooks.length; i++) {
            if (hooks[allHooks[i]].verified && !hooks[allHooks[i]].deprecated) {
                verifiedCount++;
            }
        }

        address[] memory verified = new address[](verifiedCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allHooks.length; i++) {
            if (hooks[allHooks[i]].verified && !hooks[allHooks[i]].deprecated) {
                verified[index] = allHooks[i];
                index++;
            }
        }

        return verified;
    }

    /// @notice Get hooks by category
    /// @param category Category name
    function getHooksByCategory(string calldata category) external view returns (address[] memory) {
        return hooksByCategory[category];
    }

    /// @notice Get categories for a hook
    /// @param hookAddress Hook address
    function getCategoriesForHook(address hookAddress) external view returns (string[] memory) {
        return categoriesByHook[hookAddress];
    }

    /// @notice Check if hook is safe to use
    /// @param hookAddress Hook to check
    /// @return safe True if hook is verified and not deprecated
    function isSafeHook(address hookAddress) external view returns (bool safe) {
        if (hooks[hookAddress].hookAddress == address(0)) return false;
        return hooks[hookAddress].verified && !hooks[hookAddress].deprecated;
    }
}
