# Architecture

## Purpose

`croptop-core-v6` turns a Juicebox project with a 721 tiers hook into a permissioned publishing surface. Project owners define what kinds of posts are allowed, and third parties can mint new content tiers only if their post matches those rules. A fixed fee is routed to a designated fee project on every publish.

## Boundaries

- `CTPublisher` owns publishing policy and fee routing.
- `CTDeployer` owns one-shot project creation and optional sucker setup.
- The underlying 721 tier implementation remains in `nana-721-hook-v6`.
- The repo does not reimplement terminal accounting; payments still settle through Juicebox terminals.

## Main Components

| Component | Responsibility |
| --- | --- |
| `CTPublisher` | Validates posts, creates or reuses tiers, mints the first copy, and routes publish fees |
| `CTDeployer` | Launches a Juicebox project plus hook configuration in one transaction and can proxy hook callbacks |
| `CTProjectOwner` | Burn-lock helper that permanently delegates tier adjustment authority to Croptop |
| `CTAllowedPost`, `CTPost`, related structs | Encode project-level publishing policy and publish requests |

## Runtime Model

### Publishing

```text
poster
  -> mintFrom(hook, posts, ...)
  -> publisher validates each post against project-defined criteria
  -> publisher calls the 721 hook to create or reuse tiers
  -> project terminal receives the publish payment
  -> fee project receives the fixed fee slice
  -> first copy of each created tier is minted to the poster
```

### Project Launch

```text
creator
  -> CTDeployer launches the project, hook, posting criteria, and optional suckers
  -> deployer can also stand in as a ruleset data-hook wrapper when needed
```

## Critical Invariants

- A post is valid only if it satisfies the configured category, price, supply, split, and allowlist constraints.
- Fee routing must be computed from the payment value, not transient contract balance, so forced ETH cannot distort the fee.
- `CTProjectOwner` only makes sense as a lock, not a flexible admin layer. Once a project is burn-locked, Croptop becomes the only intended tier-adjustment path.
- Publishing should not bypass the 721 hook's own invariants around tier creation and minting.

## Where Complexity Lives

- Post validation is spread across category rules, split limits, supply bounds, and optional allowlists.
- `CTDeployer` is subtle because it is both a launch helper and, in some flows, a runtime hook proxy.
- Fee routing has multiple fallback paths and needs to stay value-conserving under failure.

## Dependencies

- `nana-721-hook-v6` for tier storage and minting
- `nana-suckers-v6` and `nana-omnichain-deployers-v6` patterns when omnichain deployment is enabled
- `nana-core-v6` terminals, permissions, and project ownership

## Safe Change Guide

- Keep publishing policy separate from 721 implementation details. If a change is generally useful for all tiered collections, it belongs downstream.
- When modifying fee logic, reason through terminal payment ordering and failure fallback paths together.
- Any change to `CTDeployer` should be reviewed as both a deployer and a live hook wrapper, because it participates in runtime flows after launch.
- Changes to burn-lock semantics should be treated as governance changes, not UI conveniences.
- Be wary of adding product-specific tier semantics here that really belong in the generic 721 hook.
