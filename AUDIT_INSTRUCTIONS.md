# Audit Instructions

Croptop is a publishing layer on top of Juicebox projects and the 721 hook stack. Audit it as a permissions and fee-routing system, not just a content app.

## Objective

Find issues that:
- let publishers create or mint posts outside configured criteria
- let users evade Croptop fees or route them incorrectly
- grant fee-free or privileged cash-outs to the wrong actors
- create stale, duplicate, or abusive tier reuse across posts
- break ownership handoff or permanently lock a project in an unintended admin state

## Scope

In scope:
- `src/CTPublisher.sol`
- `src/CTDeployer.sol`
- `src/CTProjectOwner.sol`
- `src/interfaces/`
- `src/structs/`
- deployment scripts in `script/`

External integrations that matter:
- `nana-core-v6`
- `nana-721-hook-v6`
- `nana-ownable-v6`
- `nana-suckers-v6`

## System Model

Croptop has three roles:
- `CTPublisher`: validates post configuration, creates or adjusts tiers, mints the first copy, and routes fees
- `CTDeployer`: launches a project, wires hook ownership and post criteria, and acts as a data-hook proxy where required
- `CTProjectOwner`: ownership helper for projects that want Croptop-controlled administration

The system relies on project-specific posting criteria such as:
- minimum price
- supply bounds
- category restrictions
- split limits
- optional address allowlists

## Critical Invariants

1. Post criteria are binding
No publish path should bypass configured minimum price, total supply bounds, split caps, or allowlist restrictions.

2. Fee collection is complete
Each Croptop mint should either pay the configured fee or take the documented fallback path. Users must not be able to mint while underpaying Croptop.

3. Tier reuse is safe
Existing tiers must not be reusable in a way that evades fees, stale criteria, or duplicate-content protections.

4. Sucker privileges stay narrow
Any cash-out tax exemptions or mint permissions intended for legitimate suckers must not be reachable by arbitrary callers or spoofed registry state.

5. Ownership transitions are intentional
Burn-lock or project-owner helper flows must not grant broader privileges than intended or accidentally strand project administration.

## Threat Model

Prioritize:
- malicious publishers choosing edge-case prices, split structures, or reused metadata
- malicious project owners misconfiguring rules and then trying to escape them
- fake or stale sucker registrations
- fee-recipient failures that alter control flow
- reentrancy through fee routing or tier-adjustment side effects

## Hotspots

- `CTPublisher.mintFrom` and its validation pipeline
- any code path that computes fees from user-provided versus on-chain values
- tier creation or adjustment against prior post state
- `CTDeployer` data-hook behavior for pay and cash-out flows
- permission grants made during deployment or project-owner handoff
- any one-way lock or burn-based ownership design

## Build And Verification

Standard workflow:
- `npm install`
- `forge build`
- `forge test`

Current tests emphasize:
- fee evasion
- stale tier mappings
- reentrancy and attacker-controlled publish flows
- fork and omnichain composition

Strong findings usually show either fee loss, unauthorized publishing power, or a project entering a control configuration it cannot safely escape.
