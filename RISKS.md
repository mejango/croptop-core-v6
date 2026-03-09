# croptop-core-v6 — Risks

## Trust Assumptions

1. **Project Owner (CTProjectOwner)** — Controls allowed post rules, can change category restrictions and price floors. CTProjectOwner proxy manages ownership on behalf of the deployer.
2. **Publishers** — Anyone in the allowlist can post content (add NFT tiers) to a project. Posts create real economic obligations (splits, supply).
3. **CTDeployer** — Acts as data hook for deployed projects. A bug in CTDeployer affects all Croptop projects.
4. **Core Protocol** — Relies on JB721TiersHook for NFT management and JBMultiTerminal for payments.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Publisher fee extraction | Publishers receive a split of revenues from their posted tiers | Fee capped by `FEE_DIVISOR = 20` (5%) |
| Tier spam | Publishers can create many tiers, increasing gas for tier operations | Supply limits and category restrictions |
| Price floor bypass | If price floor is set too low, cheap tiers dilute project value | Configure appropriate minimum prices |
| Allowlist management | Open publishing (empty allowlist) means anyone can post | Use allowlists for curated projects |
| Cross-chain complexity | Sucker deployment adds configuration surface | Use CTSuckerDeploymentConfig carefully |

## Privileged Roles

| Role | Capabilities | Scope |
|------|-------------|-------|
| Project owner | Configure allowed posts, categories, price floors | Per-project |
| Publishers (allowlist) | Create NFT tiers (posts) | Per-project, per-category |
| CTDeployer | Data hook for all Croptop projects | All Croptop projects |
