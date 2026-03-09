# croptop-core-v6 — Architecture

## Purpose

NFT publishing platform built on Juicebox V6. Allows projects to accept permissioned NFT "posts" from community members. Posts become 721 tiers with configurable pricing, supply limits, and revenue splits. CTDeployer creates projects pre-configured for Croptop; CTPublisher handles the posting mechanics.

## Contract Map

```
src/
├── CTDeployer.sol      — Deploys Croptop projects (JB project + 721 hook + data hook)
├── CTPublisher.sol     — Permissioned NFT posting: validates posts, adds tiers, mints
├── CTProjectOwner.sol  — Holds project ownership, delegates to deployer
├── interfaces/
│   ├── ICTDeployer.sol
│   ├── ICTProjectOwner.sol
│   └── ICTPublisher.sol
└── structs/
    ├── CTAllowedPost.sol         — Post permission template
    ├── CTDeployerAllowedPost.sol  — Deployer-level post config
    ├── CTPost.sol                — Individual post data
    ├── CTProjectConfig.sol       — Project configuration
    └── CTSuckerDeploymentConfig.sol — Cross-chain config
```

## Key Data Flows

### Project Deployment
```
Creator → CTDeployer.deployProjectFor()
  → Launch JB project via JB721TiersHookProjectDeployer
  → Configure CTDeployer as data hook (controls pay/cashout)
  → Set allowed post categories and permissions
  → Configure buyback hook and suckers if specified
  → Transfer project ownership to CTProjectOwner
```

### Publishing a Post
```
Poster → CTPublisher.mintFrom(hook, posts[])
  → For each post:
    → Validate poster is in allowlist for category
    → Validate price >= minimum, supply within bounds
    → Create 721 tier with IPFS metadata
    → Configure revenue split (poster gets configured %)
    → Mint first edition to poster (pays project)
  → Fee taken (5%) and sent to fee project
```

## Extension Points

| Point | Interface | Purpose |
|-------|-----------|---------|
| Data hook | `IJBRulesetDataHook` | CTDeployer controls pay/cashout behavior |
| Post permissions | `CTAllowedPost` | Per-category posting rules |
| Token URI | `IJB721TokenUriResolver` | Custom NFT metadata |

## Dependencies
- `@bananapus/core-v6` — Core protocol
- `@bananapus/721-hook-v6` — NFT tier system
- `@bananapus/ownable-v6` — JB-aware ownership
- `@bananapus/permission-ids-v6` — Permission constants
- `@bananapus/buyback-hook-v6` — Buyback integration
- `@bananapus/suckers-v6` — Cross-chain support
- `@bananapus/router-terminal-v6` — Payment routing
- `@openzeppelin/contracts` — ERC2771, ERC721Receiver
