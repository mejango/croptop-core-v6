# User Journeys

## Repo Purpose

This repo turns a Juicebox 721 project into a permissioned publishing system. It owns post validation, Croptop fee routing, and the deployment packaging that turns a project into a Croptop-managed publisher. It does not own base terminal accounting or the underlying 721 tier mechanics.

## Primary Actors

- project owners creating a Croptop publishing surface
- publishers minting posts into an existing Croptop project
- auditors reviewing fee routing, posting policy, and owner-lock semantics

## Key Surfaces

- `CTPublisher`: validates posts, adjusts tiers, mints the first copy, and routes Croptop fees
- `CTDeployer`: launches a Croptop-shaped project and can compose omnichain deployment
- `CTProjectOwner`: owner helper that can burn-lock administration into Croptop
- `mintFrom(...)`: main publishing entrypoint

## Journey 1: Turn A Project Into A Croptop Publisher

**Actor:** project owner.

**Intent:** install Croptop publishing policy on a project.

**Preconditions**

- the project already exists or will be launched through `CTDeployer`
- the owner has chosen category rules and the expected 721 hook shape

**Main Flow**

1. Configure category-level constraints such as price floor, supply, splits, and allowlists.
2. Install or verify the expected 721 hook setup.
3. Route publishing through Croptop so future posts are policy-checked instead of free-form tier edits.

**Failure Modes**

- category rules do not match the intended publishing product
- teams assume Croptop replaces the need to audit the underlying 721 hook

**Postconditions**

- the project now routes publishing through Croptop policy instead of direct free-form tier creation

## Journey 2: Publish Content Into An Existing Croptop Project

**Actor:** publisher.

**Intent:** publish one post into a Croptop project and mint the first copy.

**Preconditions**

- the post satisfies the target project's category policy
- the caller can receive ETH if the fee refund fallback is needed
- duplicate-content and stale-tier implications are understood

**Main Flow**

1. Call `mintFrom(...)` with the content URI and pricing data.
2. `CTPublisher` validates the post against category and fee policy.
3. It creates or reuses the underlying tier, mints the first copy, and routes project revenue plus the Croptop fee.

**Failure Modes**

- duplicate URIs or stale tier mappings
- publisher inputs satisfy the base 721 hook but violate Croptop's stricter rules
- the fee terminal rejects the fee payment and `_msgSender()` cannot receive the refund

**Postconditions**

- the post is minted or reused as a tier under Croptop policy and the fee path is accounted for

## Journey 3: Launch A New Croptop Project End To End

**Actor:** product team or deployer.

**Intent:** launch a project already wired for Croptop publishing.

**Preconditions**

- the team has project config, posting rules, and any omnichain requirements ready
- the correct `FEE_PROJECT_ID` is known

**Main Flow**

1. Use `CTDeployer` with project config, posting rules, and optional omnichain config.
2. The deployer launches the project, configures Croptop ownership assumptions, and wires publisher behavior.
3. The resulting project is ready for publishers without a manual post-launch setup gap.

**Failure Modes**

- the fee project is misconfigured or omitted
- teams treat `CTDeployer` as packaging only and miss its policy implications

**Postconditions**

- the project is ready for Croptop publishers without a post-launch wiring gap

## Journey 4: Lock Administration Into Croptop's Owner Surface

**Actor:** project owner.

**Intent:** keep governance inside Croptop's constrained owner surface.

**Preconditions**

- the owner wants irreversible product-shaping constraints, not ordinary owner flexibility

**Main Flow**

1. Transfer or configure ownership so `CTProjectOwner` controls the relevant admin surface.
2. Restrict future edits to the paths Croptop intentionally exposes.
3. Accept that this is an ownership-model decision, not cosmetic packaging.

**Failure Modes**

- teams burn-lock before validating the publishing policy in production-like conditions
- reviewers miss that prior owner discretion no longer exists directly

**Postconditions**

- future administration is constrained to the Croptop owner surface instead of ordinary owner discretion

## Trust Boundaries

- this repo is trusted for publishing policy and fee routing
- the underlying 721 hook remains trusted for tier issuance and lower-level NFT accounting
- Croptop fee behavior depends on the fee project and its terminal remaining correctly configured

## Hand-Offs

- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) for the underlying tier issuance behavior Croptop wraps.
- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) when the question is about base project accounting rather than post validation or fee routing.
