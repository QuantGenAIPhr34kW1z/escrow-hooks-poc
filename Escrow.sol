// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook} from "./interfaces/IHook.sol";

/// @notice Minimal IERC20 subset (no OZ dependency).
interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title Escrow
/// @notice Enhanced composable escrow with reentrancy guard, deadlines, partial releases, and EIP-712 signatures.
/// @dev Includes storage optimization and emergency pause functionality.
/// @custom:security-contact security@example.com
contract Escrow {
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

    // Storage optimization: pack variables into slots
    struct EscrowData {
        address payer;           // 20 bytes
        State state;             // 1 byte
        bool locked;             // 1 byte (reentrancy guard)
        uint48 deadline;         // 6 bytes (timestamp, supports until year 8,921,556)
        uint32 nonce;            // 4 bytes (for EIP-712)
    }

    // ============================================
    // ERRORS
    // ============================================

    error NotPayer();
    error NotAuthorized();
    error InvalidState(State current);
    error InvalidAmount();
    error InvalidTokenTransfer();
    error InvalidETHValue();
    error ZeroAddress();
    error DeadlineExpired();
    error DeadlineNotExpired();
    error InsufficientBalance();
    error ExceedsRemainingAmount();
    error ReentrancyGuard();
    error InvalidSignature();
    error SignatureExpired();
    error IsPaused();

    // ============================================
    // EVENTS
    // ============================================

    event EscrowCreated(
        address indexed payer,
        address indexed beneficiary,
        address indexed arbiter,
        address token,
        uint256 amount,
        address hook,
        uint256 deadline
    );
    event Funded(address indexed by, uint256 amount, uint256 timestamp);
    event Released(address indexed by, address indexed to, uint256 amount, uint256 timestamp);
    event PartialRelease(address indexed by, address indexed to, uint256 amount, uint256 remaining);
    event Refunded(address indexed by, address indexed to, uint256 amount, uint256 timestamp);
    event StateChanged(State indexed from, State indexed to, uint256 timestamp);
    event HookExecuted(address indexed hook, string action, bool success);
    event Paused(address indexed by, uint256 timestamp);
    event Unpaused(address indexed by, uint256 timestamp);
    event DeadlineExtended(uint256 oldDeadline, uint256 newDeadline);

    // ============================================
    // STATE VARIABLES
    // ============================================

    EscrowData public data;

    address public immutable beneficiary;
    address public immutable arbiter;
    address public immutable token;   // 0 = ETH
    uint256 public immutable amount;

    IHook public immutable hook;

    uint256 public releasedAmount;

    // EIP-712 Domain Separator
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant RELEASE_TYPEHASH = keccak256(
        "Release(address beneficiary,uint256 amount,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant REFUND_TYPEHASH = keccak256(
        "Refund(address payer,uint256 amount,uint256 nonce,uint256 deadline)"
    );

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(
        address _payer,
        address _beneficiary,
        address _arbiter,
        address _token,
        uint256 _amount,
        address _hook,
        uint256 _deadline
    ) {
        if (_payer == address(0) || _beneficiary == address(0)) revert ZeroAddress();
        if (_amount == 0) revert InvalidAmount();
        if (_deadline != 0 && _deadline <= block.timestamp) revert DeadlineExpired();

        data.payer = _payer;
        data.state = State.Created;
        data.locked = false;
        data.deadline = uint48(_deadline);
        data.nonce = 0;

        beneficiary = _beneficiary;
        arbiter = _arbiter;
        token = _token;
        amount = _amount;
        hook = IHook(_hook);

        // Setup EIP-712 domain separator
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Escrow")),
                keccak256(bytes("2")),
                block.chainid,
                address(this)
            )
        );

        emit EscrowCreated(_payer, _beneficiary, _arbiter, _token, _amount, _hook, _deadline);
    }

    // ============================================
    // MODIFIERS
    // ============================================

    modifier onlyPayer() {
        if (msg.sender != data.payer) revert NotPayer();
        _;
    }

    modifier onlyAuthorized() {
        if (msg.sender != data.payer && (arbiter == address(0) || msg.sender != arbiter)) {
            revert NotAuthorized();
        }
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

    modifier beforeDeadline() {
        if (data.deadline != 0 && block.timestamp >= data.deadline) revert DeadlineExpired();
        _;
    }

    // ============================================
    // MAIN FUNCTIONS
    // ============================================

    /// @notice Fund the escrow with ETH or ERC20 tokens
    function fund() external payable onlyPayer nonReentrant notPaused beforeDeadline {
        if (data.state != State.Created) revert InvalidState(data.state);

        // Hook (optional)
        if (address(hook) != address(0)) {
            try hook.beforeFund(msg.sender, amount) {
                emit HookExecuted(address(hook), "beforeFund", true);
            } catch {
                emit HookExecuted(address(hook), "beforeFund", false);
                revert("Hook blocked fund");
            }
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

    /// @notice Release full amount to beneficiary
    function release() external onlyAuthorized nonReentrant notPaused {
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        uint256 remaining = amount - releasedAmount;
        _release(beneficiary, remaining);
    }

    /// @notice Partial release to beneficiary
    /// @param releaseAmount Amount to release (must not exceed remaining)
    function partialRelease(uint256 releaseAmount) external onlyAuthorized nonReentrant notPaused {
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        uint256 remaining = amount - releasedAmount;
        if (releaseAmount == 0 || releaseAmount > remaining) revert ExceedsRemainingAmount();

        releasedAmount += releaseAmount;

        if (address(hook) != address(0)) {
            try hook.beforeRelease(beneficiary) {
                emit HookExecuted(address(hook), "beforeRelease", true);
            } catch {
                emit HookExecuted(address(hook), "beforeRelease", false);
                revert("Hook blocked release");
            }
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
    }

    /// @notice Release with EIP-712 signature from arbiter
    /// @param releaseAmount Amount to release
    /// @param signatureDeadline Signature expiry timestamp
    /// @param v Signature component
    /// @param r Signature component
    /// @param s Signature component
    function releaseWithSignature(
        uint256 releaseAmount,
        uint256 signatureDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant notPaused {
        if (block.timestamp > signatureDeadline) revert SignatureExpired();
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        // Verify signature
        bytes32 structHash = keccak256(
            abi.encode(RELEASE_TYPEHASH, beneficiary, releaseAmount, data.nonce, signatureDeadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = ecrecover(digest, v, r, s);

        if (signer != arbiter && signer != data.payer) revert InvalidSignature();

        data.nonce++;

        uint256 remaining = amount - releasedAmount;
        if (releaseAmount > remaining) revert ExceedsRemainingAmount();

        releasedAmount += releaseAmount;

        if (address(hook) != address(0)) {
            try hook.beforeRelease(beneficiary) {
                emit HookExecuted(address(hook), "beforeRelease", true);
            } catch {
                emit HookExecuted(address(hook), "beforeRelease", false);
                revert("Hook blocked release");
            }
        }

        State oldState = data.state;
        if (releasedAmount == amount) {
            data.state = State.Released;
        } else {
            data.state = State.PartiallyReleased;
        }

        _payout(beneficiary, releaseAmount);

        emit PartialRelease(signer, beneficiary, releaseAmount, amount - releasedAmount);
        if (oldState != data.state) {
            emit StateChanged(oldState, data.state, block.timestamp);
        }
    }

    /// @notice Refund to payer
    function refund() external onlyAuthorized nonReentrant notPaused {
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        uint256 remaining = amount - releasedAmount;

        if (address(hook) != address(0)) {
            try hook.beforeRefund(data.payer) {
                emit HookExecuted(address(hook), "beforeRefund", true);
            } catch {
                emit HookExecuted(address(hook), "beforeRefund", false);
                revert("Hook blocked refund");
            }
        }

        State oldState = data.state;
        data.state = State.Refunded;

        _payout(data.payer, remaining);

        emit Refunded(msg.sender, data.payer, remaining, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    /// @notice Refund after deadline expires (payer can self-refund)
    function refundAfterDeadline() external onlyPayer nonReentrant notPaused {
        if (data.deadline == 0 || block.timestamp < data.deadline) revert DeadlineNotExpired();
        if (data.state != State.Funded && data.state != State.PartiallyReleased) {
            revert InvalidState(data.state);
        }

        uint256 remaining = amount - releasedAmount;

        if (address(hook) != address(0)) {
            try hook.beforeRefund(data.payer) {
                emit HookExecuted(address(hook), "beforeRefund", true);
            } catch {
                // Allow refund even if hook fails after deadline
                emit HookExecuted(address(hook), "beforeRefund", false);
            }
        }

        State oldState = data.state;
        data.state = State.Refunded;

        _payout(data.payer, remaining);

        emit Refunded(msg.sender, data.payer, remaining, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    // ============================================
    // EMERGENCY FUNCTIONS
    // ============================================

    /// @notice Pause the escrow (arbiter only)
    function pause() external nonReentrant {
        if (msg.sender != arbiter) revert NotAuthorized();
        if (data.state == State.Paused) revert InvalidState(data.state);
        if (data.state == State.Released || data.state == State.Refunded) {
            revert InvalidState(data.state);
        }

        State oldState = data.state;
        data.state = State.Paused;

        emit Paused(msg.sender, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    /// @notice Unpause the escrow (arbiter only)
    /// @param newState State to transition to after unpause
    function unpause(State newState) external nonReentrant {
        if (msg.sender != arbiter) revert NotAuthorized();
        if (data.state != State.Paused) revert InvalidState(data.state);
        if (newState == State.Paused || newState == State.Released || newState == State.Refunded) {
            revert InvalidState(newState);
        }

        State oldState = data.state;
        data.state = newState;

        emit Unpaused(msg.sender, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    /// @notice Extend deadline (authorized parties only)
    /// @param newDeadline New deadline timestamp
    function extendDeadline(uint256 newDeadline) external onlyAuthorized {
        if (data.deadline == 0) revert("No deadline set");
        if (newDeadline <= data.deadline) revert("Must extend, not shorten");

        uint256 oldDeadline = data.deadline;
        data.deadline = uint48(newDeadline);

        emit DeadlineExtended(oldDeadline, newDeadline);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _release(address to, uint256 releaseAmount) internal {
        if (address(hook) != address(0)) {
            try hook.beforeRelease(to) {
                emit HookExecuted(address(hook), "beforeRelease", true);
            } catch {
                emit HookExecuted(address(hook), "beforeRelease", false);
                revert("Hook blocked release");
            }
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

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /// @notice Get remaining amount that can be released
    function remainingAmount() external view returns (uint256) {
        return amount - releasedAmount;
    }

    /// @notice Get payer address
    function payer() external view returns (address) {
        return data.payer;
    }

    /// @notice Get current state
    function state() external view returns (State) {
        return data.state;
    }

    /// @notice Get deadline
    function deadline() external view returns (uint256) {
        return data.deadline;
    }

    /// @notice Get nonce for EIP-712
    function nonce() external view returns (uint256) {
        return data.nonce;
    }

    /// @notice Check if deadline has passed
    function isDeadlinePassed() external view returns (bool) {
        if (data.deadline == 0) return false;
        return block.timestamp >= data.deadline;
    }
}
