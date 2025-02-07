// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IHook} from "./interfaces/IHook.sol";

/// @notice Minimal ERC721 interface
interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Minimal ERC1155 interface
interface IERC1155 {
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @title EscrowNFT
/// @notice Escrow contract for NFTs (ERC-721 and ERC-1155)
/// @dev Supports single or multiple NFTs with hooks
contract EscrowNFT {
    // ============================================
    // ENUMS & STRUCTS
    // ============================================

    enum State {
        Created,
        Funded,
        Released,
        Refunded,
        Paused
    }

    enum TokenType {
        ERC721,
        ERC1155
    }

    struct NFTDeposit {
        address collection;
        uint256 tokenId;
        uint256 amount; // For ERC1155 (ignored for ERC721)
        TokenType tokenType;
    }

    struct EscrowData {
        address payer;
        State state;
        bool locked;
        uint48 deadline;
    }

    // ============================================
    // ERRORS
    // ============================================

    error NotPayer();
    error NotAuthorized();
    error InvalidState(State current);
    error InvalidNFTCount();
    error ZeroAddress();
    error DeadlineExpired();
    error ReentrancyGuard();
    error IsPaused();
    error NotERC721Receiver();
    error NotERC1155Receiver();

    // ============================================
    // EVENTS
    // ============================================

    event EscrowCreated(
        address indexed payer,
        address indexed beneficiary,
        address indexed arbiter,
        uint256 nftCount,
        address hook,
        uint256 deadline
    );
    event NFTFunded(address indexed collection, uint256 tokenId, uint256 amount, TokenType tokenType);
    event NFTReleased(address indexed to, uint256 nftCount, uint256 timestamp);
    event NFTRefunded(address indexed to, uint256 nftCount, uint256 timestamp);
    event StateChanged(State indexed from, State indexed to, uint256 timestamp);
    event Paused(address indexed by, uint256 timestamp);

    // ============================================
    // STATE VARIABLES
    // ============================================

    EscrowData public data;

    address public immutable beneficiary;
    address public immutable arbiter;

    NFTDeposit[] public nftDeposits;
    uint256 public expectedNFTCount;
    uint256 public depositedNFTCount;

    IHook public immutable hook;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    constructor(
        address _payer,
        address _beneficiary,
        address _arbiter,
        NFTDeposit[] memory _expectedNFTs,
        address _hook,
        uint256 _deadline
    ) {
        if (_payer == address(0) || _beneficiary == address(0)) revert ZeroAddress();
        if (_expectedNFTs.length == 0) revert InvalidNFTCount();

        data.payer = _payer;
        data.state = State.Created;
        data.locked = false;
        data.deadline = uint48(_deadline);

        beneficiary = _beneficiary;
        arbiter = _arbiter;
        hook = IHook(_hook);
        expectedNFTCount = _expectedNFTs.length;

        // Store expected NFTs
        for (uint256 i = 0; i < _expectedNFTs.length; i++) {
            nftDeposits.push(_expectedNFTs[i]);
        }

        emit EscrowCreated(_payer, _beneficiary, _arbiter, _expectedNFTs.length, _hook, _deadline);
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

    // ============================================
    // FUNDING FUNCTIONS
    // ============================================

    /// @notice Fund escrow with all NFTs at once
    function fundAll() external onlyPayer nonReentrant notPaused {
        if (data.state != State.Created) revert InvalidState(data.state);
        if (data.deadline != 0 && block.timestamp >= data.deadline) revert DeadlineExpired();

        if (address(hook) != address(0)) {
            hook.beforeFund(msg.sender, expectedNFTCount);
        }

        // Transfer all NFTs
        for (uint256 i = 0; i < nftDeposits.length; i++) {
            _transferNFTToEscrow(i);
        }

        depositedNFTCount = expectedNFTCount;

        State oldState = data.state;
        data.state = State.Funded;

        emit StateChanged(oldState, data.state, block.timestamp);
    }

    /// @notice Fund escrow with single NFT (for gradual funding)
    /// @param index Index of the NFT in nftDeposits array
    function fundSingle(uint256 index) external onlyPayer nonReentrant notPaused {
        if (data.state != State.Created) revert InvalidState(data.state);
        if (index >= nftDeposits.length) revert InvalidNFTCount();

        _transferNFTToEscrow(index);
        depositedNFTCount++;

        if (depositedNFTCount == expectedNFTCount) {
            State oldState = data.state;
            data.state = State.Funded;
            emit StateChanged(oldState, data.state, block.timestamp);
        }
    }

    // ============================================
    // RELEASE & REFUND
    // ============================================

    function release() external onlyAuthorized nonReentrant notPaused {
        if (data.state != State.Funded) revert InvalidState(data.state);

        if (address(hook) != address(0)) {
            hook.beforeRelease(beneficiary);
        }

        State oldState = data.state;
        data.state = State.Released;

        // Transfer all NFTs to beneficiary
        for (uint256 i = 0; i < nftDeposits.length; i++) {
            _transferNFTFromEscrow(i, beneficiary);
        }

        emit NFTReleased(beneficiary, nftDeposits.length, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    function refund() external onlyAuthorized nonReentrant notPaused {
        if (data.state != State.Funded) revert InvalidState(data.state);

        if (address(hook) != address(0)) {
            hook.beforeRefund(data.payer);
        }

        State oldState = data.state;
        data.state = State.Refunded;

        // Transfer all NFTs back to payer
        for (uint256 i = 0; i < nftDeposits.length; i++) {
            _transferNFTFromEscrow(i, data.payer);
        }

        emit NFTRefunded(data.payer, nftDeposits.length, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    function pause() external nonReentrant {
        if (msg.sender != arbiter) revert NotAuthorized();
        if (data.state == State.Paused) revert InvalidState(data.state);

        State oldState = data.state;
        data.state = State.Paused;

        emit Paused(msg.sender, block.timestamp);
        emit StateChanged(oldState, data.state, block.timestamp);
    }

    // ============================================
    // INTERNAL FUNCTIONS
    // ============================================

    function _transferNFTToEscrow(uint256 index) internal {
        NFTDeposit memory nft = nftDeposits[index];

        if (nft.tokenType == TokenType.ERC721) {
            IERC721(nft.collection).safeTransferFrom(msg.sender, address(this), nft.tokenId);
        } else {
            IERC1155(nft.collection).safeTransferFrom(
                msg.sender,
                address(this),
                nft.tokenId,
                nft.amount,
                ""
            );
        }

        emit NFTFunded(nft.collection, nft.tokenId, nft.amount, nft.tokenType);
    }

    function _transferNFTFromEscrow(uint256 index, address to) internal {
        if (to == address(0)) revert ZeroAddress();

        NFTDeposit memory nft = nftDeposits[index];

        if (nft.tokenType == TokenType.ERC721) {
            IERC721(nft.collection).safeTransferFrom(address(this), to, nft.tokenId);
        } else {
            IERC1155(nft.collection).safeTransferFrom(
                address(this),
                to,
                nft.tokenId,
                nft.amount,
                ""
            );
        }
    }

    // ============================================
    // ERC721/ERC1155 RECEIVER
    // ============================================

    /// @notice Handle ERC721 token receipt
    function onERC721Received(
        address /*operator*/,
        address /*from*/,
        uint256 /*tokenId*/,
        bytes calldata /*data*/
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @notice Handle ERC1155 token receipt
    function onERC1155Received(
        address /*operator*/,
        address /*from*/,
        uint256 /*id*/,
        uint256 /*value*/,
        bytes calldata /*data*/
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    /// @notice Handle ERC1155 batch receipt
    function onERC1155BatchReceived(
        address /*operator*/,
        address /*from*/,
        uint256[] calldata /*ids*/,
        uint256[] calldata /*values*/,
        bytes calldata /*data*/
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function payer() external view returns (address) {
        return data.payer;
    }

    function state() external view returns (State) {
        return data.state;
    }

    function deadline() external view returns (uint256) {
        return data.deadline;
    }

    function getNFTDeposit(uint256 index) external view returns (NFTDeposit memory) {
        return nftDeposits[index];
    }

    function getAllNFTDeposits() external view returns (NFTDeposit[] memory) {
        return nftDeposits;
    }

    function getNFTCount() external view returns (uint256) {
        return nftDeposits.length;
    }

    function getFundingProgress() external view returns (uint256 deposited, uint256 expected) {
        return (depositedNFTCount, expectedNFTCount);
    }
}
