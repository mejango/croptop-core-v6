# croptop-core-v6 — Risks

## Trust Assumptions

1. **Project Owner (via CTProjectOwner)** — Can configure allowed post categories, set permissions, and manage the underlying JB project. CTProjectOwner delegates management to the deployer.
2. **Posters** — Must be in the allowlist for their category. Can set price and supply within configured bounds. Revenue split configured per category.
3. **CTDeployer** — Acts as data hook for all Croptop projects. A bug in CTDeployer affects every Croptop project's pay/cashout behavior.
4. **721 Hook** — Tier management delegated to JB721TiersHook. Tier integrity depends on hook correctness.

## Known Risks

| Risk | Description | Mitigation |
|------|-------------|------------|
| Fee extraction | 5% fee (FEE_DIVISOR = 20) taken on every post | By design; sent to fee project |
| Post spam | Allowlisted posters can create many tiers | Supply and price minimums; project owner controls allowlist |
| Split percent abuse | Poster configures their revenue split within bounds | Maximum split percent enforced per allowed post config |
| Category conflicts | Multiple allowed post configs for same category | Last configuration wins; project owner manages |
| Tier accumulation | Each post creates a new 721 tier — tiers grow unboundedly | Gas costs increase with tier count; no hard cap |

## Privileged Roles

| Role | Capabilities | Scope |
|------|-------------|-------|
| Project owner | Configure allowed posts, manage project | Per-project |
| Allowlisted posters | Create posts within configured bounds | Per-category |
| CTDeployer | Data hook for all Croptop projects | All Croptop projects |
| Fee project | Receives 5% of post payments | Global |
