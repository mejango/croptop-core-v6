# croptop-core-v6 — Architecture

## Purpose

NFT publishing platform built on Juicebox V6. Allows permissioned posting of NFT content to Juicebox projects. CTDeployer creates projects pre-configured for content publishing, and CTPublisher manages the posting workflow with configurable rules (price floors, supply limits, category restrictions).

## Contract Map

```
src/
├── CTDeployer.sol       — Deploys Croptop projects with 721 hooks and publishing rules
├── CTPublisher.sol      — Manages permissioned NFT posting to projects
├── CTProjectOwner.sol   — Proxy owner for Croptop-deployed projects
├── interfaces/
│   ├── ICTDeployer.sol
│   └── ICTPublisher.sol
└── structs/
    ├── CTAllowedPost.sol         — Rules for what can be posted
    ├── CTDeployerAllowedPost.sol — Deployer-level post rules
    ├── CTPost.sol                — A post submission
    ├── CTProjectConfig.sol       — Project configuration
    └── CTSuckerDeploymentConfig.sol — Cross-chain config
```

## Key Data Flows

### Project Deployment
```
Creator → CTDeployer.deployProjectFor()
  → Launch JB project via JB721TiersHookProjectDeployer
  → Configure CTDeployer as data hook
  → Set allowed post rules (price floors, supply limits, categories)
  → Transfer project ownership to CTProjectOwner proxy
```

### Content Publishing
```
Publisher → CTPublisher.postFor(projectId, posts[])
  → For each post:
    → Validate against allowed post rules
      → Check category permissions
      → Check price >= minimum
      → Check supply within bounds
      → Check publisher in allowlist (if restricted)
    → Add NFT tier to project's 721 hook
    → Configure split for publisher (fee share)
  → Pay project to mint NFTs
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook | `IJBRulesetDataHook` | CTDeployer acts as data hook |
| 721 hook | `IJB721TiersHook` | NFT tier management |
| Publisher | `ICTPublisher` | Content posting workflow |

## Dependencies
- `@bananapus/core-v6` — Core protocol
- `@bananapus/721-hook-v6` — NFT tier system
- `@bananapus/ownable-v6` — JB-aware ownership
- `@bananapus/permission-ids-v6` — Permission constants
- `@bananapus/buyback-hook-v6` — Buyback integration
- `@bananapus/suckers-v6` — Cross-chain support
- `@bananapus/router-terminal-v6` — Payment routing
- `@openzeppelin/contracts` — ERC2771, ERC721Receiver
