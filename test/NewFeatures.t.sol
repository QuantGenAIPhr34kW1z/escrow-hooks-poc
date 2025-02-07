// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {EscrowMultiSig} from "../EscrowMultiSig.sol";
import {EscrowNFT} from "../EscrowNFT.sol";
import {ZkProofHook} from "../hooks/ZkProofHook.sol";
import {OracleHook} from "../hooks/OracleHook.sol";
import {TimeLockedHook} from "../hooks/TimeLockedHook.sol";
import {MultiSigHook} from "../hooks/MultiSigHook.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {IHook} from "../interfaces/IHook.sol";

// Mock contracts
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "Not owner");
        ownerOf[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }
}

contract MockERC1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata
    ) external {
        require(balanceOf[from][id] >= amount, "Insufficient balance");
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
    }

    function setApprovalForAll(address, bool) external {}
}

contract MockVerifier is IVerifier {
    bytes32 public immutable expected;

    constructor(bytes32 _expected) {
        expected = _expected;
    }

    function verify(bytes calldata proof, bytes32 publicInputHash) external view returns (bool) {
        if (publicInputHash != expected) return false;
        return keccak256(proof) == keccak256(bytes("valid"));
    }
}

contract MockAggregator {
    int256 public price;
    uint256 public updatedAt;
    uint8 public constant decimals = 8;

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (0, price, 0, updatedAt, 0);
    }
}

contract NewFeaturesTest is Test {
    address payer = address(0xA11CE);
    address beneficiary = address(0xB0B);
    address arbiter1 = address(0xCAFE);
    address arbiter2 = address(0xBEEF);
    address arbiter3 = address(0xDEAD);

    // ============================================
    // MULTI-SIG ESCROW TESTS
    // ============================================

    function test_MultiSigEscrow_Basic() public {
        address[] memory arbiters = new address[](3);
        arbiters[0] = arbiter1;
        arbiters[1] = arbiter2;
        arbiters[2] = arbiter3;

        EscrowMultiSig escrow = new EscrowMultiSig(
            payer,
            beneficiary,
            arbiters,
            2, // 2-of-3
            address(0),
            1 ether,
            address(0),
            0
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        // First arbiter approves
        vm.prank(arbiter1);
        escrow.approveRelease();

        assertEq(escrow.getReleaseApprovalCount(), 1);

        // Second arbiter approves
        vm.prank(arbiter2);
        escrow.approveRelease();

        assertEq(escrow.getReleaseApprovalCount(), 2);

        // Now release can be executed
        vm.prank(arbiter1);
        escrow.release();

        assertEq(beneficiary.balance, 1 ether);
        assertEq(uint256(escrow.state()), uint256(EscrowMultiSig.State.Released));
    }

    function test_MultiSigEscrow_InsufficientApprovals() public {
        address[] memory arbiters = new address[](3);
        arbiters[0] = arbiter1;
        arbiters[1] = arbiter2;
        arbiters[2] = arbiter3;

        EscrowMultiSig escrow = new EscrowMultiSig(
            payer,
            beneficiary,
            arbiters,
            2,
            address(0),
            1 ether,
            address(0),
            0
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        // Only one approval
        vm.prank(arbiter1);
        escrow.approveRelease();

        // Try to release - should fail
        vm.prank(arbiter2);
        vm.expectRevert(EscrowMultiSig.InsufficientApprovals.selector);
        escrow.release();
    }

    // ============================================
    // NFT ESCROW TESTS
    // ============================================

    function test_NFTEscrow_ERC721() public {
        MockERC721 nft = new MockERC721();
        nft.mint(payer, 1);
        nft.mint(payer, 2);

        // Setup NFT deposits
        EscrowNFT.NFTDeposit[] memory deposits = new EscrowNFT.NFTDeposit[](2);
        deposits[0] = EscrowNFT.NFTDeposit({
            collection: address(nft),
            tokenId: 1,
            amount: 1,
            tokenType: EscrowNFT.TokenType.ERC721
        });
        deposits[1] = EscrowNFT.NFTDeposit({
            collection: address(nft),
            tokenId: 2,
            amount: 1,
            tokenType: EscrowNFT.TokenType.ERC721
        });

        EscrowNFT escrow = new EscrowNFT(
            payer,
            beneficiary,
            arbiter1,
            deposits,
            address(0),
            0
        );

        // Approve and fund
        vm.startPrank(payer);
        nft.setApprovalForAll(address(escrow), true);
        escrow.fundAll();
        vm.stopPrank();

        assertEq(nft.ownerOf(1), address(escrow));
        assertEq(nft.ownerOf(2), address(escrow));

        // Release
        vm.prank(arbiter1);
        escrow.release();

        assertEq(nft.ownerOf(1), beneficiary);
        assertEq(nft.ownerOf(2), beneficiary);
    }

    function test_NFTEscrow_ERC1155() public {
        MockERC1155 nft = new MockERC1155();
        nft.mint(payer, 1, 100);

        EscrowNFT.NFTDeposit[] memory deposits = new EscrowNFT.NFTDeposit[](1);
        deposits[0] = EscrowNFT.NFTDeposit({
            collection: address(nft),
            tokenId: 1,
            amount: 50,
            tokenType: EscrowNFT.TokenType.ERC1155
        });

        EscrowNFT escrow = new EscrowNFT(
            payer,
            beneficiary,
            arbiter1,
            deposits,
            address(0),
            0
        );

        vm.startPrank(payer);
        nft.setApprovalForAll(address(escrow), true);
        escrow.fundAll();
        vm.stopPrank();

        assertEq(nft.balanceOf(address(escrow), 1), 50);

        vm.prank(arbiter1);
        escrow.release();

        assertEq(nft.balanceOf(beneficiary, 1), 50);
    }

    // ============================================
    // ZK PROOF HOOK  TESTS
    // ============================================

    function test_ZkProofHook() public {
        bytes32 publicInputHash = keccak256("test");
        MockVerifier verifier = new MockVerifier(publicInputHash);

        ZkProofHook hook = new ZkProofHook(
            address(verifier),
            publicInputHash,
            address(this),
            address(this),
            true,
            0
        );

        // Submit valid proof
        hook.submitProof(bytes("valid"));

        assertTrue(hook.hasValidProof());
        assertTrue(hook.proofSubmitted());

        // Hook should pass
        hook.beforeRelease(beneficiary);
    }

    function test_ZkProofHook_InvalidProof() public {
        bytes32 publicInputHash = keccak256("test");
        MockVerifier verifier = new MockVerifier(publicInputHash);

        ZkProofHook hook = new ZkProofHook(
            address(verifier),
            publicInputHash,
            address(this),
            address(this),
            true,
            0
        );

        // Try to submit invalid proof
        vm.expectRevert(ZkProofHook.InvalidProof.selector);
        hook.submitProof(bytes("invalid"));
    }

    function test_ZkProofHook_ProofExpiry() public {
        bytes32 publicInputHash = keccak256("test");
        MockVerifier verifier = new MockVerifier(publicInputHash);

        ZkProofHook hook = new ZkProofHook(
            address(verifier),
            publicInputHash,
            address(this),
            address(this),
            true,
            1 hours
        );

        hook.submitProof(bytes("valid"));

        // Warp past expiry
        vm.warp(block.timestamp + 2 hours);

        // Proof should be expired
        assertFalse(hook.hasValidProof());

        vm.expectRevert(ZkProofHook.ProofExpired.selector);
        hook.beforeRelease(beneficiary);
    }

    // ============================================
    // ORACLE HOOK TESTS
    // ============================================

    function test_OracleHook_MinPrice() public {
        MockAggregator aggregator = new MockAggregator();
        aggregator.setPrice(2000_00000000); // $2000

        OracleHook hook = new OracleHook(
            address(aggregator),
            address(this),
            1 hours
        );

        hook.setReleaseMinPrice(1500_00000000); // Min $1500

        // Should pass
        hook.beforeRelease(beneficiary);

        // Lower price
        aggregator.setPrice(1000_00000000); // $1000

        // Should fail
        vm.expectRevert();
        hook.beforeRelease(beneficiary);
    }

    function test_OracleHook_MaxPrice() public {
        MockAggregator aggregator = new MockAggregator();
        aggregator.setPrice(2000_00000000);

        OracleHook hook = new OracleHook(
            address(aggregator),
            address(this),
            1 hours
        );

        hook.setReleaseMaxPrice(2500_00000000); // Max $2500

        // Should pass
        hook.beforeRelease(beneficiary);

        // Higher price
        aggregator.setPrice(3000_00000000); // $3000

        // Should fail
        vm.expectRevert();
        hook.beforeRelease(beneficiary);
    }

    function test_OracleHook_StalePrice() public {
        MockAggregator aggregator = new MockAggregator();
        aggregator.setPrice(2000_00000000);

        OracleHook hook = new OracleHook(
            address(aggregator),
            address(this),
            1 hours // Max age 1 hour
        );

        hook.setReleaseMinPrice(1500_00000000);

        // Warp past max age
        vm.warp(block.timestamp + 2 hours);

        // Should fail due to stale price
        vm.expectRevert();
        hook.beforeRelease(beneficiary);
    }

    // ============================================
    // TIME LOCKED HOOK TESTS
    // ============================================

    function test_TimeLockedHook_NotBefore() public {
        TimeLockedHook hook = new TimeLockedHook(address(this));

        uint256 releaseTime = block.timestamp + 7 days;

        hook.setReleaseTimeLock(releaseTime, 0);

        // Try to release early - should fail
        vm.expectRevert();
        hook.beforeRelease(beneficiary);

        // Warp to release time
        vm.warp(releaseTime);

        // Should pass now
        hook.beforeRelease(beneficiary);
    }

    function test_TimeLockedHook_NotAfter() public {
        TimeLockedHook hook = new TimeLockedHook(address(this));

        uint256 endTime = block.timestamp + 7 days;

        hook.setReleaseTimeLock(0, endTime);

        // Should pass before end time
        hook.beforeRelease(beneficiary);

        // Warp past end time
        vm.warp(endTime + 1);

        // Should fail
        vm.expectRevert();
        hook.beforeRelease(beneficiary);
    }

    function test_TimeLockedHook_Window() public {
        TimeLockedHook hook = new TimeLockedHook(address(this));

        uint256 startTime = block.timestamp + 1 days;
        uint256 endTime = block.timestamp + 7 days;

        hook.setReleaseTimeLock(startTime, endTime);

        // Before window - fail
        vm.expectRevert();
        hook.beforeRelease(beneficiary);

        // In window - pass
        vm.warp(startTime + 1 hours);
        hook.beforeRelease(beneficiary);

        // After window - fail
        vm.warp(endTime + 1);
        vm.expectRevert();
        hook.beforeRelease(beneficiary);
    }

    function test_TimeLockedHook_EmergencyOverride() public {
        TimeLockedHook hook = new TimeLockedHook(address(this));

        hook.setReleaseTimeLock(block.timestamp + 7 days, 0);

        // Enable emergency override
        hook.enableEmergencyOverride();

        // Should pass even though time lock is active
        hook.beforeRelease(beneficiary);
    }

    // ============================================
    // MULTI-SIG HOOK TESTS
    // ============================================

    function test_MultiSigHook() public {
        address[] memory signers = new address[](3);
        signers[0] = arbiter1;
        signers[1] = arbiter2;
        signers[2] = arbiter3;

        MultiSigHook hook = new MultiSigHook(
            signers,
            1, // fund threshold
            2, // release threshold
            2, // refund threshold
            0  // no expiry
        );

        // First arbiter approves release
        vm.prank(arbiter1);
        hook.approveRelease();

        // Not enough approvals yet
        vm.expectRevert();
        hook.beforeRelease(beneficiary);

        // Second arbiter approves
        vm.prank(arbiter2);
        hook.approveRelease();

        // Should pass now
        hook.beforeRelease(beneficiary);
    }

    function test_MultiSigHook_ApprovalExpiry() public {
        address[] memory signers = new address[](2);
        signers[0] = arbiter1;
        signers[1] = arbiter2;

        MultiSigHook hook = new MultiSigHook(
            signers,
            1,
            2,
            2,
            1 hours // 1 hour expiry
        );

        vm.prank(arbiter1);
        hook.approveRelease();

        vm.prank(arbiter2);
        hook.approveRelease();

        // Warp past expiry
        vm.warp(block.timestamp + 2 hours);

        // Should fail
        vm.expectRevert();
        hook.beforeRelease(beneficiary);
    }
}
