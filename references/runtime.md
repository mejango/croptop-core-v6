# Croptop Runtime

## Contract Roles

- [`src/CTPublisher.sol`](../src/CTPublisher.sol) validates posts, configures or reuses tiers, mints first copies, and routes Croptop fees.
- [`src/CTDeployer.sol`](../src/CTDeployer.sol) packages project deployment, hook forwarding, and optional sucker support.
- [`src/CTProjectOwner.sol`](../src/CTProjectOwner.sol) is the burn-lock ownership helper for immutable administration patterns.

## Runtime Path

1. A project is deployed or configured with Croptop posting rules.
2. Publishers call into [`src/CTPublisher.sol`](../src/CTPublisher.sol) with content, supply, and pricing data.
3. The publisher validates category-level rules, creates or reuses tiers, mints the first copy, and routes fees and proceeds.
4. If the project uses the deployer wrapper, data-hook calls forward through [`src/CTDeployer.sol`](../src/CTDeployer.sol).

## High-Risk Areas

- Posting criteria: category rules are the policy surface that protects the project from bad content or bad economics.
- Fee routing: fee-project assumptions and fee exemptions are operationally important.
- Tier reuse and duplicate content: content identity is part of runtime behavior, not just metadata.
- Burn-lock ownership: once ownership moves into the lock helper, reversibility expectations change drastically.

## Tests To Trust First

- [`test/regression/`](../test/regression/) for pinned content and tier edge cases.
- [`test/fork/`](../test/fork/) for live integration assumptions.
- [`test/`](../test/) broadly when the issue could be in publisher or deployer behavior rather than one isolated function.
