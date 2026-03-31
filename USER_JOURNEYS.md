# User Journeys

## Who This Repo Serves

- project owners who want community-posted NFT content
- posters publishing content into another project's collection
- operators deploying a full Croptop project in one transaction

## Journey 1: Turn A Project Into A Croptop Publisher

**Starting state:** you control a Juicebox project with a 721 hook, and you know what categories, pricing bounds, and split rules posters should follow.

**Success:** the project has explicit posting criteria and can accept compliant community posts.

**Flow**
1. Configure allowed post rules per category with `configurePostingCriteriaFor(...)`.
2. Define minimum price, supply bounds, max split percent, and optional address allowlists.
3. Keep the 721 hook permissions aligned so `CTPublisher` can create or reuse tiers.
4. Share the posting policy offchain so posters know what will validate.

**Important constraint:** Croptop does not remove editorial judgment. It formalizes it onchain.

## Journey 2: Publish Content Into An Existing Croptop Project

**Starting state:** a project has already published its Croptop rules, and your post satisfies them.

**Success:** your post becomes a mintable tier and the first copy is minted to the beneficiary you specified.

**Flow**
1. Prepare the `CTPost` payload with content URI, supply, category, price, and splits.
2. Call `mintFrom(hook, posts, nftBeneficiary, feeBeneficiary, ...)` with enough value.
3. `CTPublisher` validates each post against the project's criteria.
4. Matching posts create new tiers or reuse existing tiers when the URI already exists.
5. The project receives the payment net of Croptop's 5% fee, and the poster receives the first minted copy.

**Failure modes that matter:** invalid category rules, disallowed poster address, out-of-range price or supply, and duplicate content expectations that do not match how URI reuse works.

## Journey 3: Launch A New Croptop Project End To End

**Starting state:** you want the project, collection, and posting rules created together rather than bolted on after launch.

**Success:** a complete Croptop-ready project exists with posting rules and optional sucker support.

**Flow**
1. Build a `CTProjectConfig` with terminals, metadata, collection name and symbol, and allowed post rules.
2. Call `CTDeployer.deployProjectFor(...)`.
3. The deployer creates the Juicebox project and 721 hook, configures Croptop posting rules, and can optionally deploy suckers.
4. If you want immutable collection ownership, transfer the project NFT into `CTProjectOwner`.

## Hand-Offs

- Use [nana-721-hook-v6](../nana-721-hook-v6/USER_JOURNEYS.md) for the underlying tiered collection behavior.
- Use [nana-suckers-v6](../nana-suckers-v6/USER_JOURNEYS.md) if the Croptop project is meant to be cross-chain.
