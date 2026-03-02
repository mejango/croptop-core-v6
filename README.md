# croptop-core-v5

Permissioned NFT publishing for Juicebox projects -- anyone can post content as NFT tiers to a project's 721 hook, provided the posts meet criteria set by the project owner.

## Architecture

| Contract | Description |
|----------|-------------|
| `CTPublisher` | Core publishing engine. Validates posts against owner-configured allowances (min price, supply bounds, address allowlists), creates new 721 tiers on the hook, mints the first copy to the poster, and routes a 5% fee to a designated fee project. |
| `CTDeployer` | One-click project factory. Deploys a Juicebox project with a 721 tiers hook pre-wired, configures posting criteria via `CTPublisher`, optionally deploys cross-chain suckers, and acts as a `IJBRulesetDataHook` proxy that forwards pay/cash-out calls to the underlying hook while granting fee-free cash outs to suckers. |
| `CTProjectOwner` | Burn-lock ownership helper. Receives a project's ERC-721 ownership token and automatically grants `CTPublisher` the `ADJUST_721_TIERS` permission, effectively making the project's tier configuration immutable except through Croptop posts. |

### Structs

| Struct | Purpose |
|--------|---------|
| `CTAllowedPost` | Full posting criteria including hook address, category, price/supply bounds, and address allowlist. |
| `CTDeployerAllowedPost` | Same as `CTAllowedPost` but without the hook address (inferred during deployment). |
| `CTPost` | A post to publish: encoded IPFS URI, total supply, price, and category. |
| `CTProjectConfig` | Project deployment configuration: terminals, metadata URIs, allowed posts, collection name/symbol, and salt. |
| `CTSuckerDeploymentConfig` | Cross-chain sucker deployment: deployer configurations and deterministic salt. |

## Install

```bash
npm install @croptop/core-v5
```

## Develop

`croptop-core-v5` uses [npm](https://www.npmjs.com/) for package management and [Foundry](https://github.com/foundry-rs/foundry) for builds, tests, and deployments.

```bash
curl -L https://foundry.paradigm.xyz | sh
npm install && forge install
```

| Command | Description |
|---------|-------------|
| `forge build` | Compile contracts and write artifacts to `out`. |
| `forge test` | Run the test suite. |
| `forge fmt` | Lint Solidity files. |
| `forge build --sizes` | Get contract sizes. |
| `forge coverage` | Generate a test coverage report. |
| `forge clean` | Remove build artifacts and cache. |
