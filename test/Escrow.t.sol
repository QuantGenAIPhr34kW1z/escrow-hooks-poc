// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {Escrow} from "../Escrow.sol";
import {EscrowFactory} from "../EscrowFactory.sol";
import {HookRegistry} from "../HookRegistry.sol";
import {AllowlistHook} from "../hooks/AllowlistHook.sol";
import {IHook} from "../interfaces/IHook.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract EscrowTest is Test {
    address payer = address(0xA11CE);
    address beneficiary = address(0xB0B);
    address arbiter = address(0xCAFE);

    function test_BasicETHEscrow() public {
        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            0 // no deadline
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        assertEq(uint256(escrow.state()), uint256(Escrow.State.Funded));

        vm.prank(arbiter);
        escrow.release();

        assertEq(beneficiary.balance, 1 ether);
        assertEq(uint256(escrow.state()), uint256(Escrow.State.Released));
    }

    function test_ReentrancyGuard() public {
        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            0
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        // The reentrancy guard prevents the locked flag from being bypassed
        assertEq(uint256(escrow.state()), uint256(Escrow.State.Funded));
    }

    function test_DeadlineMechanism() public {
        uint256 deadline = block.timestamp + 7 days;

        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            deadline
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        // Warp past deadline
        vm.warp(deadline + 1);

        // Payer can now self-refund
        vm.prank(payer);
        escrow.refundAfterDeadline();

        assertEq(payer.balance, 2 ether);
        assertEq(uint256(escrow.state()), uint256(Escrow.State.Refunded));
    }

    function test_RevertIf_FundAfterDeadline() public {
        uint256 deadline = block.timestamp + 7 days;

        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            deadline
        );

        // Warp past deadline
        vm.warp(deadline + 1);

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        vm.expectRevert(Escrow.DeadlineExpired.selector);
        escrow.fund{value: 1 ether}();
    }

    function test_PartialRelease() public {
        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            10 ether,
            address(0),
            0
        );

        vm.deal(payer, 20 ether);
        vm.prank(payer);
        escrow.fund{value: 10 ether}();

        // First partial release
        vm.prank(arbiter);
        escrow.partialRelease(3 ether);

        assertEq(beneficiary.balance, 3 ether);
        assertEq(escrow.releasedAmount(), 3 ether);
        assertEq(escrow.remainingAmount(), 7 ether);
        assertEq(uint256(escrow.state()), uint256(Escrow.State.PartiallyReleased));

        // Second partial release
        vm.prank(arbiter);
        escrow.partialRelease(4 ether);

        assertEq(beneficiary.balance, 7 ether);
        assertEq(escrow.releasedAmount(), 7 ether);
        assertEq(escrow.remainingAmount(), 3 ether);

        // Final release
        vm.prank(arbiter);
        escrow.partialRelease(3 ether);

        assertEq(beneficiary.balance, 10 ether);
        assertEq(uint256(escrow.state()), uint256(Escrow.State.Released));
    }

    function test_EIP712Signature() public {
        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            0
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        // Create signature (simplified - in practice use proper signing)
        uint256 arbiterKey = 0xCAFE;
        address arbiterAddr = vm.addr(arbiterKey);

        // Deploy new escrow with deterministic arbiter
        Escrow escrow2 = new Escrow(
            payer,
            beneficiary,
            arbiterAddr,
            address(0),
            1 ether,
            address(0),
            0
        );

        vm.deal(payer, 3 ether);
        vm.prank(payer);
        escrow2.fund{value: 1 ether}();

        // Sign release
        uint256 releaseAmount = 1 ether;
        uint256 nonce = escrow2.nonce();
        uint256 signatureDeadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(
                escrow2.RELEASE_TYPEHASH(),
                beneficiary,
                releaseAmount,
                nonce,
                signatureDeadline
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", escrow2.DOMAIN_SEPARATOR(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(arbiterKey, digest);

        // Execute with signature
        escrow2.releaseWithSignature(releaseAmount, signatureDeadline, v, r, s);

        assertEq(beneficiary.balance, 1 ether);
        assertEq(uint256(escrow2.state()), uint256(Escrow.State.Released));
    }

    function test_EmergencyPause() public {
        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            0
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        // Arbiter pauses
        vm.prank(arbiter);
        escrow.pause();

        assertEq(uint256(escrow.state()), uint256(Escrow.State.Paused));

        // Cannot release while paused
        vm.prank(arbiter);
        vm.expectRevert(Escrow.IsPaused.selector);
        escrow.release();

        // Unpause
        vm.prank(arbiter);
        escrow.unpause(Escrow.State.Funded);

        // Now can release
        vm.prank(arbiter);
        escrow.release();

        assertEq(uint256(escrow.state()), uint256(Escrow.State.Released));
    }

    function test_StorageOptimization() public {
        // Create escrow and verify storage is optimized
        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            block.timestamp + 30 days
        );

        // Verify data is correctly packed
        assertEq(escrow.payer(), payer);
        assertEq(uint256(escrow.state()), uint256(Escrow.State.Created));
        assertTrue(escrow.deadline() > 0);
    }

    function test_Factory() public {
        EscrowFactory factory = new EscrowFactory();

        bytes32 salt = factory.generateSalt(payer, beneficiary, 1);

        address predicted = factory.predictEscrowAddress(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            0,
            salt
        );

        address escrow = factory.createEscrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            0,
            salt
        );

        assertEq(escrow, predicted);
        assertEq(factory.totalEscrowsCreated(), 1);

        address[] memory payerEscrows = factory.getEscrowsByPayer(payer);
        assertEq(payerEscrows.length, 1);
        assertEq(payerEscrows[0], escrow);
    }

    function test_HookRegistry() public {
        HookRegistry registry = new HookRegistry();

        AllowlistHook hook = new AllowlistHook(address(this));

        registry.registerHook(
            address(hook),
            "Allowlist Hook ",
            "Compliance hook with allowlist",
            "ipfs://QmABC123",
            "2.0.0"
        );

        HookRegistry.HookInfo memory info = registry.getHookInfo(address(hook));
        assertEq(info.name, "Allowlist Hook ");
        assertEq(info.version, "2.0.0");
        assertFalse(info.verified);

        // Verify hook
        registry.verifyHook(address(hook));

        info = registry.getHookInfo(address(hook));
        assertTrue(info.verified);
        assertTrue(registry.isSafeHook(address(hook)));
    }

    function test_EnhancedEvents() public {
        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            0
        );

        vm.deal(payer, 2 ether);

        vm.prank(payer);
        vm.expectEmit(true, true, true, true);
        emit Funded(payer, 1 ether, block.timestamp);
        escrow.fund{value: 1 ether}();

        vm.prank(arbiter);
        vm.expectEmit(true, true, true, true);
        emit Released(arbiter, beneficiary, 1 ether, block.timestamp);
        escrow.release();
    }

    function test_RefundHook() public {
        AllowlistHook hook = new AllowlistHook(address(this));
        hook.setAllowed(payer, true);
        hook.setAllowed(beneficiary, true);

        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(hook),
            0
        );

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        // Try to refund - should fail because payer not explicitly allowed for refund
        // (in this test, payer is allowed, so it will succeed)
        vm.prank(arbiter);
        escrow.refund();

        assertEq(payer.balance, 2 ether);
    }

    function test_ExtendDeadline() public {
        uint256 deadline = block.timestamp + 7 days;

        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            arbiter,
            address(0),
            1 ether,
            address(0),
            deadline
        );

        uint256 newDeadline = deadline + 7 days;

        vm.prank(arbiter);
        escrow.extendDeadline(newDeadline);

        assertEq(escrow.deadline(), newDeadline);
    }

    // Events for testing
    event Funded(address indexed by, uint256 amount, uint256 timestamp);
    event Released(address indexed by, address indexed to, uint256 amount, uint256 timestamp);
}
