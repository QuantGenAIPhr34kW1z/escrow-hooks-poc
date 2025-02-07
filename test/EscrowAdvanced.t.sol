// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {Escrow} from "../Escrow.sol";
import {AllowlistHook} from "../hooks/AllowlistHook.sol";
import {ZkProofHook} from "../hooks/ZkProofHook.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {IHook} from "../interfaces/IHook.sol";

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

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
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        require(balanceOf[from] >= amt, "bal");
        allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract BadERC20 {
    // Does NOT return bool
    function transfer(address, uint256) external pure {}
    function transferFrom(address, address, uint256) external pure {}
}

contract RevertingHook is IHook {
    bool public shouldRevertOnFund;
    bool public shouldRevertOnRelease;

    function setShouldRevertOnFund(bool _should) external {
        shouldRevertOnFund = _should;
    }

    function setShouldRevertOnRelease(bool _should) external {
        shouldRevertOnRelease = _should;
    }

    function beforeFund(address, uint256) external view override {
        if (shouldRevertOnFund) revert("Hook blocked fund");
    }

    function beforeRelease(address) external view override {
        if (shouldRevertOnRelease) revert("Hook blocked release");
    }
}

contract EscrowAdvancedTest is Test {
    address payer = address(0xA11CE);
    address beneficiary = address(0xB0B);
    address arbiter = address(0xCAFE);
    address randomUser = address(0xDEAD);

    // Test: Cannot create escrow with zero payer
    function test_RevertIf_PayerIsZero() public {
        vm.expectRevert(Escrow.ZeroAddress.selector);
        new Escrow(address(0), beneficiary, arbiter, address(0), 1 ether, address(0));
    }

    // Test: Cannot create escrow with zero beneficiary
    function test_RevertIf_BeneficiaryIsZero() public {
        vm.expectRevert(Escrow.ZeroAddress.selector);
        new Escrow(payer, address(0), arbiter, address(0), 1 ether, address(0));
    }

    // Test: Cannot create escrow with zero amount
    function test_RevertIf_AmountIsZero() public {
        vm.expectRevert(Escrow.InvalidAmount.selector);
        new Escrow(payer, beneficiary, arbiter, address(0), 0, address(0));
    }

    // Test: Can create escrow without arbiter (arbiter = 0)
    function test_CreateEscrow_WithoutArbiter() public {
        Escrow escrow = new Escrow(payer, beneficiary, address(0), address(0), 1 ether, address(0));
        assertEq(escrow.arbiter(), address(0));
        assertEq(uint256(escrow.state()), uint256(Escrow.State.Created));
    }

    // Test: Non-payer cannot fund
    function test_RevertIf_NonPayerTries ToFund() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.deal(randomUser, 2 ether);
        vm.prank(randomUser);
        vm.expectRevert(Escrow.NotPayer.selector);
        escrow.fund{value: 1 ether}();
    }

    // Test: Cannot fund with wrong ETH amount
    function test_RevertIf_WrongETHAmount() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        vm.expectRevert(Escrow.InvalidETHValue.selector);
        escrow.fund{value: 0.5 ether}();
    }

    // Test: Cannot send ETH when funding ERC20 escrow
    function test_RevertIf_SendETHToERC20Escrow() public {
        MockERC20 token = new MockERC20();
        token.mint(payer, 1000e18);

        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(token), 100e18, address(0));

        vm.deal(payer, 1 ether);
        vm.prank(payer);
        vm.expectRevert(Escrow.InvalidETHValue.selector);
        escrow.fund{value: 1 ether}();
    }

    // Test: Cannot fund twice
    function test_RevertIf_FundTwice() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.deal(payer, 3 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidState.selector, Escrow.State.Funded));
        escrow.fund{value: 1 ether}();
    }

    // Test: Cannot release before funding
    function test_RevertIf_ReleaseBeforeFunding() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidState.selector, Escrow.State.Created));
        escrow.release();
    }

    // Test: Cannot refund before funding
    function test_RevertIf_RefundBeforeFunding() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidState.selector, Escrow.State.Created));
        escrow.refund();
    }

    // Test: Non-authorized cannot release
    function test_RevertIf_NonAuthorizedTriesToRelease() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        vm.prank(randomUser);
        vm.expectRevert(Escrow.NotAuthorized.selector);
        escrow.release();
    }

    // Test: Arbiter can release
    function test_ArbiterCanRelease() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        uint256 beforeBal = beneficiary.balance;
        vm.prank(arbiter);
        escrow.release();

        assertEq(beneficiary.balance, beforeBal + 1 ether);
        assertEq(uint256(escrow.state()), uint256(Escrow.State.Released));
    }

    // Test: Arbiter can refund
    function test_ArbiterCanRefund() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        uint256 beforeBal = payer.balance;
        vm.prank(arbiter);
        escrow.refund();

        assertEq(payer.balance, beforeBal + 1 ether);
        assertEq(uint256(escrow.state()), uint256(Escrow.State.Refunded));
    }

    // Test: Cannot release after refund
    function test_RevertIf_ReleaseAfterRefund() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        vm.prank(payer);
        escrow.refund();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidState.selector, Escrow.State.Refunded));
        escrow.release();
    }

    // Test: Cannot refund after release
    function test_RevertIf_RefundAfterRelease() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        vm.prank(payer);
        escrow.release();

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Escrow.InvalidState.selector, Escrow.State.Released));
        escrow.refund();
    }

    // Test: Hook can block funding
    function test_HookCanBlockFunding() public {
        RevertingHook hook = new RevertingHook();
        hook.setShouldRevertOnFund(true);

        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(hook));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        vm.expectRevert("Hook blocked fund");
        escrow.fund{value: 1 ether}();
    }

    // Test: Hook can block release
    function test_HookCanBlockRelease() public {
        RevertingHook hook = new RevertingHook();

        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(hook));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        hook.setShouldRevertOnRelease(true);

        vm.prank(payer);
        vm.expectRevert("Hook blocked release");
        escrow.release();
    }

    // Test: AllowlistHook batch operations
    function test_AllowlistHook_BatchOperations() public {
        AllowlistHook hook = new AllowlistHook(address(this));

        address[] memory addresses = new address[](3);
        addresses[0] = payer;
        addresses[1] = beneficiary;
        addresses[2] = randomUser;

        hook.setAllowedBatch(addresses, true);

        assertTrue(hook.allowed(payer));
        assertTrue(hook.allowed(beneficiary));
        assertTrue(hook.allowed(randomUser));

        // Now disallow them all
        hook.setAllowedBatch(addresses, false);

        assertFalse(hook.allowed(payer));
        assertFalse(hook.allowed(beneficiary));
        assertFalse(hook.allowed(randomUser));
    }

    // Test: AllowlistHook zero address protection
    function test_AllowlistHook_RevertIf_TransferOwnershipToZero() public {
        AllowlistHook hook = new AllowlistHook(address(this));

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        hook.transferOwnership(address(0));
    }

    // Test: AllowlistHook ownership transfer
    function test_AllowlistHook_OwnershipTransfer() public {
        AllowlistHook hook = new AllowlistHook(address(this));

        assertEq(hook.owner(), address(this));

        hook.transferOwnership(randomUser);

        assertEq(hook.owner(), randomUser);
    }

    // Test: ERC20 escrow with insufficient approval
    function test_RevertIf_ERC20InsufficientApproval() public {
        MockERC20 token = new MockERC20();
        token.mint(payer, 1000e18);

        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(token), 100e18, address(0));

        vm.prank(payer);
        token.approve(address(escrow), 50e18); // Approve less than needed

        vm.prank(payer);
        vm.expectRevert(Escrow.InvalidTokenTransfer.selector);
        escrow.fund();
    }

    // Test: ERC20 escrow with insufficient balance
    function test_RevertIf_ERC20InsufficientBalance() public {
        MockERC20 token = new MockERC20();
        token.mint(payer, 50e18); // Mint less than needed

        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(token), 100e18, address(0));

        vm.prank(payer);
        token.approve(address(escrow), 100e18);

        vm.prank(payer);
        vm.expectRevert(Escrow.InvalidTokenTransfer.selector);
        escrow.fund();
    }

    // Test: Events are emitted correctly
    function test_EventsEmitted() public {
        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), 1 ether, address(0));

        vm.deal(payer, 2 ether);

        // Test Funded event
        vm.prank(payer);
        vm.expectEmit(true, true, true, true);
        emit Funded(payer, 1 ether);
        escrow.fund{value: 1 ether}();

        // Test Released event
        vm.prank(payer);
        vm.expectEmit(true, true, true, true);
        emit Released(payer, beneficiary, 1 ether);
        escrow.release();
    }

    // Test: Payer-only control when no arbiter
    function test_PayerOnlyControl_WhenNoArbiter() public {
        Escrow escrow = new Escrow(payer, beneficiary, address(0), address(0), 1 ether, address(0));

        vm.deal(payer, 2 ether);
        vm.prank(payer);
        escrow.fund{value: 1 ether}();

        // Payer can release
        vm.prank(payer);
        escrow.release();

        assertEq(uint256(escrow.state()), uint256(Escrow.State.Released));
    }

    // Test: Fuzz test for various amounts
    function testFuzz_ETHEscrow_VariousAmounts(uint96 amount) public {
        vm.assume(amount > 0);

        Escrow escrow = new Escrow(payer, beneficiary, arbiter, address(0), amount, address(0));

        vm.deal(payer, uint256(amount) * 2);
        vm.prank(payer);
        escrow.fund{value: amount}();

        uint256 beforeBal = beneficiary.balance;
        vm.prank(payer);
        escrow.release();

        assertEq(beneficiary.balance, beforeBal + amount);
    }

    // Events (needed for expectEmit)
    event Funded(address indexed by, uint256 amount);
    event Released(address indexed by, address indexed to, uint256 amount);
    event Refunded(address indexed by, address indexed to, uint256 amount);
}
