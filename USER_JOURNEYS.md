# User Journeys

## Who This Repo Serves

- project owners turning a Juicebox 721 project into a publishing marketplace
- publishers creating or reusing NFT tiers as posts
- operators locking project administration into Croptop-specific ownership patterns

## Journey 1: Turn A Project Into A Croptop Publisher

**Starting state:** a project already exists or is about to launch, and the owner wants category-level posting rules.

**Success:** Croptop posting criteria are installed and future posts must satisfy them.

**Flow**
1. Configure category-level posting constraints such as price floor, supply bounds, split limits, and optional allowlists.
2. Install or verify the 721 hook shape the project expects.
3. Route the project through Croptop's publisher logic so future post creation is policy-checked instead of free-form tier editing.

## Journey 2: Publish Content Into An Existing Croptop Project

**Starting state:** a publisher has a post that satisfies the target project's posting rules.

**Success:** the post becomes a valid 721 tier and the first mint settles correctly.

**Flow**
1. The publisher calls `mintFrom(...)` or the equivalent publishing surface with the content URI and pricing data.
2. `CTPublisher` checks the post against category rules and fee policy.
3. It creates or reuses the underlying 721 tier, mints the first copy, and routes both project revenue and the Croptop fee. If the fee terminal is unavailable, the fee is refunded to `_msgSender()` instead.

**Failure cases that matter:** duplicate URIs, split configurations that evade fees, stale tier mappings, publisher inputs that satisfy the 721 hook but violate Croptop's stricter publishing rules, and callers that cannot receive ETH when a fee refund fallback is needed.

## Journey 3: Launch A New Croptop Project End To End

**Starting state:** the product wants a fresh project that already has Croptop deployment choices baked in.

**Success:** one deployment flow launches the project, wires the 721 hook, and installs the initial posting rules.

**Flow**
1. Use `CTDeployer` with project config, posting rules, and any omnichain deployment config.
2. The deployer launches the Juicebox project, configures the Croptop-specific owner model, and wires in publisher behavior.
3. The project is ready for publishers without a manual post-launch setup phase.

## Journey 4: Lock Administration Into Croptop's Owner Surface

**Starting state:** the project should continue operating through Croptop's policy surface instead of ordinary project-owner discretion.

**Success:** the project's admin path is burn-locked or otherwise routed through `CTProjectOwner`.

**Flow**
1. Transfer or configure ownership so Croptop's owner helper controls the relevant admin surface.
2. Restrict future edits to the paths Croptop intentionally exposes.
3. Accept that this is a product-shaping choice, not a cosmetic deployment detail.

## Journey 5: Support Cross-Chain Payments Through Data Hooks

**Starting state:** a sucker pays the Croptop project on behalf of a remote user via `payRemote`, and `CTDeployer.beforePayRecordedWith` needs to forward the correct beneficiary to downstream hooks.

**Success:** downstream data hooks see the real remote user so any hook-specific accounting accrues to the right person.

**Flow**
1. The sucker calls `terminal.pay()` with relay-beneficiary metadata.
2. `CTDeployer.beforePayRecordedWith()` resolves the relay beneficiary when the payer is a registered sucker.
3. The swapped beneficiary is forwarded to the downstream data hook.

## Hand-Offs

- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) for the underlying tier issuance behavior Croptop wraps.
- Use [nana-core-v6](../nana-core-v6/USER_JOURNEYS.md) when the question is about base project accounting rather than post validation or fee routing.
