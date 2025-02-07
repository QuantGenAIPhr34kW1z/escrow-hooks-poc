// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook} from "./interfaces/IHook.sol";

/// @notice Minimal IERC20 subset
interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title EscrowMultiSig
/// @notice Escrow with native M-of-N multi-signature support for arbiters
/// @dev Combines Escrow features with built-in multi-sig functionality
contract EscrowMultiSig {
    // ============================================
    // ENUMS & STRUCTS
    // ============================================

    enum State {
        Created,
        Funded,
        PartiallyReleased,
        Released,
        Refunded,
        Paused
    }

    struct ArbiterApproval {
        uint256 releaseCount;
        uint256 refundCount;
        mapping(address => bool) hasApprovedRelease;
        mapping(address => bool) hasApprovedRefund;
    }

    struct EscrowData {
        address payer;
        State state;
        bool locked;
        uint48 deadline;
        uint32 nonce;
    }

    // ============================================
    // ERRORS
    // ============================================

    error NotPayer();
    error NotArbiter();
    error InsufficientApprovals();
    error InvalidState(State current);
    error InvalidAmount();
    error InvalidTokenTransfer();
    error InvalidETHValue();
    error ZeroAddress();
    error DeadlineExpired();
    error ExceedsRemainingAmount();
    error ReentrancyGuard();
    error IsPaused();
    error InvalidThreshold();
    error AlreadyApproved();

    // ============================================
    // EVENTS
    // ============================================

    event EscrowCreated(
        address indexed payer,
        address indexed beneficiary,
        address[] arbiters,
        uint256 arbiterThreshold,
        address token,
        uint256 amount,
        address hook,
        uint256 deadline
    );
    event Funded(address indexed by, uint256 amount, uint256 timestamp);
    event ReleaseApproved(address indexed arbiter, uint256 approvalCount, uint256 required);
    event RefundApproved(address indexed arbiter, uint256 approvalCount, uint256 required);
    event Released(address indexed by, address indexed to, uint256 amount, uint256 timestamp);
    event PartialRelease(address indexed by, address indexed to, uint256 amount, uint256 remaining);
    event Refunded(address indexed by, address indexed to, uint256 amount, uint256 timestamp);
    event StateChanged(State indexed from, State indexed to, uint256 timestamp);
    event Paused(address indexed by, uint256 timestamp);
    event Unpaused(address indexed by, uint256 timestamp);

    // ============================================
    // STATE VARIABLES
    // ============================================

    EscrowData public data;

    address public immutable beneficiary;
    address public immutable token;
    uint256 public immutable amount;

    address[] public arbiters;
    mapping(address => bool) public isArbiter;
    uint256 public arbiterThreshold; // M in M-of-N

    ArbiterApproval private approvals;

    IHook public immutable hook;
    uint256 public releasedAmount;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(
        address _payer,
        address _beneficiary,
        address[] memory _arbiters,
        uint256 _arbiterThreshold,
        address _token,
        uint256 _amount,
        address _hook,
        uint256 _deadline
    ) {
        if (_payer == address(0) || _beneficiary == address(0)) revert ZeroAddress();
        if (_amount == 0) revert InvalidAmount();
        if (_arbiters.length == 0) revert ZeroAddress();
        if (_arbiterThreshold == 0 || _arbiterThreshold > _arbiters.length) revert InvalidThreshold();

        data.payer = _payer;
        data.state = State.Created;
        data.locked = false;
        data.deadline = uint48(_deadline);
        data.nonce = 0;

        beneficiary = _beneficiary;
        token = _token;
        amount = _amount;
        hook = IHook(_hook);
        arbiterThreshold = _arbiterThreshold;

        // Setup arbiters
        for (uint256 i = 0; i < _arbiters.length; i++) {
            address arbiter = _arbiters[i];
            if (arbiter == address(0)) revert ZeroAddress();
            if (isArbiter[arbiter]) continue; // Skip duplicates

            arbiters.push(arbiter);
            isArbiter[arbiter] = true;
        }

        emit EscrowCreated(
            _payer,
            _beneficiary,
            _arbiters,
            _arbiterThreshold,
            _token,
            _amount,
            _hook,
            _deadline
        );
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyPayer() {
        if (msg.sender != data.payer) revert NotPayer();
        _;
    }

    modifier onlyArbiter() {
        if (!isArbiter[msg.sender]) revert NotArbiter();
        _;
    }

    modifier nonReentrant() {
        if (data.locked) revert ReentrancyGuard();
        data.locked = true;
        _;
        data.locked = false;
    }

    modifier notPaused() {
        if (data.state == State.Paused) revert IsPaused();
        _;
    }

    // ============================================
    // MAIN FUNCTIONS
    // ============================================

    function fund() external payable onlyPayer nonReentrant notPaused {
        if (data.state != State.Created) revert InvalidState(data.state);
        if (data.deadline != 0 && block.timestamp >= data.deadline) revert DeadlineExpired();

        if (address(hook) != address(0)) {
            hook.beforeFund(msg.sender, amount);
        }

        if (token == address(0)) {
            if (msg.value != amount) revert InvalidETHValue();
        } else {
            if (msg.value != 0) revert InvalidETHValue();
            bool ok = IERC20Like(token).transferFrom(msg.sender, address(this), amount);
            if (!ok) revert InvalidTokenTransfer();
        }

        State oldState = data.state;
        data.state = State.Funded;

        emit Funded(msg.sender, amount, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    /// @notice Arbiters approve release
    function approveRelease() external onlyArbiter nonReentrant notPaused {
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        if (approvals.hasApprovedRelease[msg.sender]) revert AlreadyApproved();

        approvals.hasApprovedRelease[msg.sender] = true;
        approvals.releaseCount++;

        emit ReleaseApproved(msg.sender, approvals.releaseCount, arbiterThreshold);
    }

    /// @notice Execute release after enough approvals
    function release() external nonReentrant notPaused {
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        // Check if enough approvals (payer can always release, or M-of-N arbiters)
        if (msg.sender != data.payer) {
            if (approvals.releaseCount < arbiterThreshold) {
                revert InsufficientApprovals();
            }
        }

        uint256 remaining = amount - releasedAmount;
        _release(beneficiary, remaining);

        // Reset approvals after use
        _resetReleaseApprovals();
    }

    /// @notice Partial release with multi-sig
    function partialRelease(uint256 releaseAmount) external nonReentrant notPaused {
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        // Check approvals
        if (msg.sender != data.payer) {
            if (approvals.releaseCount < arbiterThreshold) {
                revert InsufficientApprovals();
            }
        }

        uint256 remaining = amount - releasedAmount;
        if (releaseAmount == 0 || releaseAmount > remaining) revert ExceedsRemainingAmount();

        releasedAmount += releaseAmount;

        if (address(hook) != address(0)) {
            hook.beforeRelease(beneficiary);
        }

        State oldState = data.state;
        if (releasedAmount == amount) {
            data.state = State.Released;
        } else {
            data.state = State.PartiallyReleased;
        }

        _payout(beneficiary, releaseAmount);

        emit PartialRelease(msg.sender, beneficiary, releaseAmount, amount - releasedAmount);
        if (oldState != data.state) {
            emit StateChanged(oldState, data.state, block.timestamp);
        }

        // Reset approvals after use
        _resetReleaseApprovals();
    }

    /// @notice Arbiters approve refund
    function approveRefund() external onlyArbiter nonReentrant notPaused {
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        if (approvals.hasApprovedRefund[msg.sender]) revert AlreadyApproved();

        approvals.hasApprovedRefund[msg.sender] = true;
        approvals.refundCount++;

        emit RefundApproved(msg.sender, approvals.refundCount, arbiterThreshold);
    }

    /// @notice Execute refund after enough approvals
    function refund() external nonReentrant notPaused {
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        // Check approvals (payer can always refund, or M-of-N arbiters)
        if (msg.sender != data.payer) {
            if (approvals.refundCount < arbiterThreshold) {
                revert InsufficientApprovals();
            }
        }

        uint256 remaining = amount - releasedAmount;

        if (address(hook) != address(0)) {
            hook.beforeRefund(data.payer);
        }

        State oldState = data.state;
        data.state = State.Refunded;

        _payout(data.payer, remaining);

        emit Refunded(msg.sender, data.payer, remaining, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);

        // Reset approvals
        _resetRefundApprovals();
    }

    /// @notice Pause escrow (requires arbiter threshold approvals)
    function pause() external onlyArbiter nonReentrant {
        if (data.state == State.Paused) revert InvalidState(data.state);

        State oldState = data.state;
        data.state = State.Paused;

        emit Paused(msg.sender, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _release(address to, uint256 releaseAmount) internal {
        if (address(hook) != address(0)) {
            hook.beforeRelease(to);
        }

        State oldState = data.state;
        data.state = State.Released;
        releasedAmount = amount;

        _payout(to, releaseAmount);

        emit Released(msg.sender, to, releaseAmount, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    function _payout(address to, uint256 payoutAmount) internal {
        if (to == address(0)) revert ZeroAddress();

        if (token == address(0)) {
            (bool ok, ) = to.call{value: payoutAmount}("");
            if (!ok) revert InvalidTokenTransfer();
        } else {
            bool ok = IERC20Like(token).transfer(to, payoutAmount);
            if (!ok) revert InvalidTokenTransfer();
        }
    }

    function _resetReleaseApprovals() internal {
        approvals.releaseCount = 0;
        for (uint256 i = 0; i < arbiters.length; i++) {
            approvals.hasApprovedRelease[arbiters[i]] = false;
        }
    }

    function _resetRefundApprovals() internal {
        approvals.refundCount = 0;
        for (uint256 i = 0; i < arbiters.length; i++) {
            approvals.hasApprovedRefund[arbiters[i]] = false;
        }
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function remainingAmount() external view returns (uint256) {
        return amount - releasedAmount;
    }

    function payer() external view returns (address) {
        return data.payer;
    }

    function state() external view returns (State) {
        return data.state;
    }

    function getReleaseApprovalCount() external view returns (uint256) {
        return approvals.releaseCount;
    }

    function getRefundApprovalCount() external view returns (uint256) {
        return approvals.refundCount;
    }

    function hasApprovedRelease(address arbiter) external view returns (bool) {
        return approvals.hasApprovedRelease[arbiter];
    }

    function hasApprovedRefund(address arbiter) external view returns (bool) {
        return approvals.hasApprovedRefund[arbiter];
    }

    function getArbiters() external view returns (address[] memory) {
        return arbiters;
    }
}
