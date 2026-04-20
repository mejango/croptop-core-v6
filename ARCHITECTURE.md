# Architecture

## Purpose

`croptop-core-v6` turns a Juicebox project with a 721 tiers hook into a permissioned publishing market. Project owners define what posts are valid, third parties publish content by minting or reusing tiers, and Croptop routes a fixed publish fee to the canonical fee project.

## System Overview

`CTPublisher` is the runtime policy and fee-routing surface. `CTDeployer` is the launch-time wrapper that can package a project, its 721 hook configuration, posting rules, and optional omnichain setup in one transaction. `CTProjectOwner` is the irreversible ownership helper for projects that want Croptop-mediated administration instead of a plain owner EOA.

## Core Invariants

- A post can only be published if it satisfies the configured category, pricing, supply, split, and allowlist rules.
- Publish fees must be computed from the call value, not from ambient contract balance.
- `CTPublisher` must not trap fee funds. If the fee-project payment fails, the fee is refunded to `_msgSender()`, and if that refund fails the publish reverts.
- Tier creation and minting must continue to respect `nana-721-hook-v6` invariants.
- `CTDeployer` intentionally creates a temporary owner-bypass period before collection ownership is claimed away from the deployer.
- `CTProjectOwner` is a burn-lock primitive, not a flexible admin panel.

## Modules

| Module | Responsibility | Notes |
| --- | --- | --- |
| `CTPublisher` | Post validation, tier reuse or creation, first-copy minting, fee routing | Main runtime contract |
| `CTDeployer` | Project launch, hook wiring, optional sucker setup, wrapper behavior | Launch-time and runtime wrapper |
| `CTProjectOwner` | Irreversible ownership helper | Governance-sensitive |
| `CTAllowedPost`, `CTPost`, related structs | Publishing policy and request encoding | Shared config surface |

## Trust Boundaries

- Tier storage and minting semantics live in `nana-721-hook-v6`.
- Terminal accounting and project ownership live in `nana-core-v6`.
- When omnichain setup is enabled, this repo composes deployer patterns from `nana-suckers-v6` and `nana-omnichain-deployers-v6` instead of reimplementing them.

## Critical Flows

### Publish

```text
poster
  -> calls mintFrom(...)
  -> publisher validates each post against project policy
  -> publisher creates or reuses 721 tiers
  -> project terminal receives the publish payment
  -> fee project receives the fixed fee slice, or `_msgSender()` is refunded if that fee payment fails
  -> first copy of each post tier is minted to the poster
```

### Launch

```text
creator
  -> CTDeployer launches the project and 721-hook shape
  -> configures Croptop posting rules
  -> optionally wires omnichain sucker deployment
  -> may remain in the flow as a runtime wrapper when hook composition is enabled
```

## Accounting Model

This repo does not define treasury accounting. Its critical economic logic is publish-fee routing and the mapping from valid post data to 721 tier creation or reuse.

`CTPublisher` also relies on duplicate-content and pricing checks to stop fee evasion through batch composition or tier reuse. Those checks are part of economic correctness, not just content hygiene.

## Security Model

- Fee routing is liveness-first but still value-sensitive; fallback refunds must stay correct.
- `CTDeployer` has a larger review surface than a normal deployer because it can also participate at runtime.
- Croptop's product boundary is partly social: until collection ownership is claimed away from `CTDeployer`, the project owner can interact through the granted permissions rather than only through the publisher surface.
- Posting policy bugs are product-level authorization bugs, not just metadata bugs.

## Safe Change Guide

- Put generic tier logic in `nana-721-hook-v6`, not here.
- If fee behavior changes, review payment ordering, fee-project fallback, and refund failure handling together.
- If deployer ownership or permission grants change, re-check the temporary bypass window and post-claim ownership behavior together.
- If `CTDeployer` changes, test both project launch and any wrapped hook flow it participates in.
- Treat `CTProjectOwner` changes as governance changes.

## Canonical Checks

- publish-path fee routing and policy enforcement:
  `test/CTPublisher.t.sol`
- fee fallback and refund safety:
  `test/audit/FeeFallbackBlackhole.t.sol`
- duplicate-content and batch-fee-evasion resistance:
  `test/regression/DuplicateUriFeeEvasion.t.sol`

## Source Map

- `src/CTPublisher.sol`
- `src/CTDeployer.sol`
- `src/CTProjectOwner.sol`
- `test/CTPublisher.t.sol`
- `test/audit/FeeFallbackBlackhole.t.sol`
- `test/regression/DuplicateUriFeeEvasion.t.sol`
