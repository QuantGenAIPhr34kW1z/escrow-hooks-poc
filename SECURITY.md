
# Security Policy

## Scope

This repository provides reference implementations and patterns for composable escrow hooks.
It is **not** a production deployment by default.

## Reporting a vulnerability

Please do **not** open public issues for potential vulnerabilities.

Instead:
- open a private security advisory (preferred), or
- email the maintainer(s) via the address listed on the GitHub profile.

Include:
- a description of the issue
- impact assessment (who can exploit, what can be stolen)
- minimal PoC (Foundry test preferred)
- suggested fix (if known)

## Disclosure

We aim to:
- acknowledge within a few days
- provide a fix or mitigation plan
- publish a coordinated disclosure if the issue is confirmed

## Notes

Hooks are **explicit external calls**. Any hook can:
- revert (intentionally blocking actions)
- consume gas
- emit events
- implement arbitrary policy

When deploying, treat hook code as part of your trusted computing base.


