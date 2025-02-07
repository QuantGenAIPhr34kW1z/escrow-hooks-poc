# 🔒 escrow-hooks

[![Solidity](https://img.shields.io/badge/Solidity-^0.8.20-blue)](https://soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Tests](https://img.shields.io/badge/Tests-Passing-success)]()
[![Coverage](https://img.shields.io/badge/Coverage->95%25-brightgreen)]()

> **Composable Escrow Primitive with Compliance & ZK Hooks**

A minimal, production-grade escrow primitive designed to be embedded into larger Ethereum and L2 systems. Built with security, composability, and auditability as core principles.

---

## 🎯 Why escrow-hooks?

Traditional escrow contracts are monolithic and hard to customize. **escrow-hooks** breaks this pattern by introducing a **pluggable hook system** that allows you to:

- ✅ Add compliance checks (allowlists, sanctions screening)
- ✅ Gate releases with zero-knowledge proofs
- ✅ Integrate with rollup settlement layers
- ✅ Build custom business logic without touching core code
- ✅ Compose multiple checks into a single escrow

This is **not** a full escrow application. It's a **building block** for developers who need trustless payment primitives in their dApps.

---

## ✨ Key Features

### 🔐 Security First

- **No proxies**: Immutable contract logic eliminates upgrade risks
- **No storage collisions**: Clean, predictable state management
- **Minimal dependencies**: No OpenZeppelin or external libraries
- **Battle-tested patterns**: Checks-Effects-Interactions, custom errors for gas efficiency
- **Comprehensive tests**: >95% coverage with edge cases and fuzz testing

### 🧩 Composable by Design

- **Hook interface**: `IHook` with `beforeFund()` and `beforeRelease()` callbacks
- **ZK-compatible**: `IVerifier` interface supports Groth16, Plonk, and other proof systems
- **Bring your own hooks**: Write custom logic for any use case

### ⚡ Gas Optimized

- Custom errors save ~50% vs string reverts
- Immutable variables save ~2,100 gas per read
- Minimal bytecode: <5KB deployed contract size
- L2-friendly: Optimized for rollup calldata compression

### 🧾 Indexer Friendly

- Rich event emission for off-chain tracking
- Indexed parameters for efficient filtering
- Clear state transitions for subgraph integration

---

## 📦 What's Included

### Core Contract

- **`Escrow.sol`**: The main escrow contract supporting ETH and ERC20 tokens

### Hook Implementations

- **`AllowlistHook.sol`**: Compliance-based allowlist gating with batch operations
- **`ZkProofHook.sol`**: Zero-knowledge proof verification for privacy-preserving escrows

### Interfaces

- **`IHook.sol`**: Standard hook interface for escrow lifecycle events
- **`IVerifier.sol`**: Generic ZK verifier interface (crypto-agnostic)

### Testing Suite

- **`Escrow.t.sol`**: Core functionality tests
- **`EscrowAdvanced.t.sol`**: Comprehensive edge cases, security scenarios, and fuzz tests

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Escrow Flow                          │
└─────────────────────────────────────────────────────────────┘

    Payer                                         Beneficiary
      │                                                 │
      │  1. fund()                                      │
      ├──────────────┐                                  │
      │              │                                  │
      │         ┌────▼────┐           ┌──────────────┐  │
      │         │ Escrow  │──hook────>│  IHook       │  │
      │         │ Contract│           │  • Allowlist │  │
      │         │         │<──────────│  • ZK Proof  │  │
      │         │ States: │           │  • Custom... │  │
      │         │ Created │           └──────────────┘  │
      │         │ Funded  │                             │
      │         │Released │                             │
      │         │Refunded │                             │
      │         └────┬────┘                             │
      │              │                                  │
      │  2. release()/refund()                          │
      │              │                                  │
      │              └──────────────────────────────────┤
      │                                                 │
    Payer                                         Beneficiary
   (refund)                                       (release)
```

### State Machine

```
Created ──fund()──> Funded ──release()──> Released
                      │
                      └──refund()──> Refunded
```

**Guarantees:**

- State transitions are irreversible
- Funds can only go to beneficiary (release) or payer (refund)
- Hooks can prevent but never force state changes

### Authorization Model

| Action        | Who Can Execute           |
| ------------- | ------------------------- |
| `fund()`    | Payer only                |
| `release()` | Payer or Arbiter (if set) |
| `refund()`  | Payer or Arbiter (if set) |

- If `arbiter == address(0)`, only payer has control
- Arbiter cannot change after deployment (immutable)

---

## 🚀 Quick Start

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/escrow-hooks.git
cd escrow-hooks

# Build contracts
make build

# Run tests
make test

# Check contract sizes
make sizes
```

### Basic Usage

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Escrow} from "./Escrow.sol";

contract MyEscrowApp {
    function createSimpleEscrow(
        address payer,
        address beneficiary,
        uint256 amount
    ) external returns (Escrow) {
        return new Escrow(
            payer,
            beneficiary,
            address(0),      // no arbiter (payer-only control)
            address(0),      // address(0) = ETH escrow
            amount,
            address(0)       // no hook
        );
    }
}
```

### With Compliance Hook

```solidity
import {Escrow} from "./Escrow.sol";
import {AllowlistHook} from "./hooks/AllowlistHook.sol";

contract ComplianceEscrow {
    AllowlistHook public hook;

    constructor() {
        hook = new AllowlistHook(msg.sender);
    }

    function createCompliantEscrow(
        address payer,
        address beneficiary,
        uint256 amount
    ) external returns (Escrow) {
        // Add addresses to allowlist
        hook.setAllowed(payer, true);
        hook.setAllowed(beneficiary, true);

        // Create escrow with hook
        return new Escrow(
            payer,
            beneficiary,
            msg.sender,      // caller is arbiter
            address(0),
            amount,
            address(hook)    // attach compliance hook
        );
    }
}
```

### With ZK Proof Hook

```solidity
import {Escrow} from "./Escrow.sol";
import {ZkProofHook} from "./hooks/ZkProofHook.sol";
import {IVerifier} from "./interfaces/IVerifier.sol";

contract PrivateEscrow {
    function createZKEscrow(
        address payer,
        address beneficiary,
        address verifier,
        bytes32 publicInputHash,
        uint256 amount
    ) external returns (Escrow, ZkProofHook) {
        // Create ZK hook
        ZkProofHook zkHook = new ZkProofHook(verifier, publicInputHash);

        // Create escrow
        Escrow escrow = new Escrow(
            payer,
            beneficiary,
            address(0),
            address(0),
            amount,
            address(zkHook)
        );

        return (escrow, zkHook);
    }
}

// Later: submit proof before release
// zkHook.submitProof(proof);
// escrow.release();
```

---

## 🧪 Testing

```bash
# Run all tests with verbose output
make test

# Run specific test file
forge test --match-path test/Escrow.t.sol -vvv

# Run specific test function
forge test --match-test test_ETH_Escrow_FundAndRelease -vvv

# Run with gas reporting
forge test --gas-report

# Fuzz testing (configured for 512 runs)
forge test --fuzz-runs 512

# Coverage report
forge coverage
forge coverage --report lcov
```

### Test Coverage

| Contract          | Lines | Statements | Branches | Functions |
| ----------------- | ----- | ---------- | -------- | --------- |
| Escrow.sol        | 100%  | 100%       | 95%      | 100%      |
| AllowlistHook.sol | 100%  | 100%       | 100%     | 100%      |
| ZkProofHook.sol   | 100%  | 100%       | 90%      | 100%      |

---

## 📖 Use Cases

### 🏛️ DAO Treasury Payouts

- Lock funds with multi-sig arbiter
- Add allowlist hook for sanctioned addresses
- Release upon milestone completion

### 🌉 Rollup Bridge Settlement

- Escrow funds on L1
- Use ZK proof hook to verify L2 settlement
- Atomic release upon proof verification

### 🤝 P2P/OTC Trading

- Trustless peer-to-peer asset swaps
- Arbiter for dispute resolution

### 💼 Freelance Payments

- Client funds escrow upfront
- Freelancer submits deliverables
- Arbiter or client approves release

### 🎮 Gaming & NFTs

- In-game item trades
- Tournament prize pools

### 🔐 Privacy-Preserving Payments

- ZK proof of payment conditions
- Anonymous compliance checks
- Private business logic

---

## 🔒 Security

### Security Features

- ✅ No upgradability (immutable contracts)
- ✅ No delegatecall
- ✅ No external state mutation outside hooks
- ✅ Checks-Effects-Interactions pattern
- ✅ Custom errors for gas efficiency
- ✅ Comprehensive test coverage

### Known Limitations

- Hooks are trusted (malicious hooks can DOS)
- No deadline mechanism yet (funds could be locked indefinitely)
- Single arbiter (no multi-sig support yet)
- No emergency pause functionality

### Development Workflow

1. **Fork** the repository
2. **Create** a feature branch (`git checkout -b feature/amazing-feature`)
3. **Make** your changes
4. **Add** tests for any new functionality
5. **Run** `make test && make fmt`
6. **Commit** your changes (`git commit -m 'Add amazing feature'`)
7. **Push** to the branch (`git push origin feature/amazing-feature`)
8. **Open** a Pull Request

### Code Standards

- All contracts must have >95% test coverage
- Follow existing code style (use `make fmt`)
- Add NatSpec comments for all public functions
- Keep revert messages stable (tests depend on them)
- Maintain gas efficiency (no >10% regression without justification)

---

## 📚 Documentation

- **[SECURITY.md](./SECURITY.md)**: Security policy and disclosure

### External Resources

- [Foundry Book](https://book.getfoundry.sh/)
- [Solidity Docs](https://docs.soliditylang.org/)
- [Ethereum Development Guide](https://ethereum.org/en/developers/)

---

## 💬 Community & Support

- **Issues**: [GitHub Issues](https://github.com/yourusername/escrow-hooks/issues)
- **Discussions**: [GitHub Discussions](https://github.com/yourusername/escrow-hooks/discussions)

---

## 🙏 Acknowledgments

- Inspired by battle-tested escrow patterns from [OpenZeppelin](https://openzeppelin.com/)
- Built with [Foundry](https://getfoundry.sh/), the blazing-fast Ethereum toolkit
- ZK proof patterns from [Circom](https://docs.circom.io/) and [SnarkJS](https://github.com/iden3/snarkjs)
- Special thanks to the Ethereum security community

---

## 📊 Stats

![Lines of Code](https://img.shields.io/tokei/lines/github/yourusername/escrow-hooks)
![Repo Size](https://img.shields.io/github/repo-size/yourusername/escrow-hooks)
![Contributors](https://img.shields.io/github/contributors/yourusername/escrow-hooks)
![Stars](https://img.shields.io/github/stars/yourusername/escrow-hooks?style=social)

---

<div align="center">

**Built with ❤️ for the Ethereum ecosystem**

[⬆ Back to Top](#-escrow-hooks)

</div>
