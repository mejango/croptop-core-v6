// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Hook721Deployment, Hook721DeploymentLib} from "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import {SuckerDeployment, SuckerDeploymentLib} from "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {CTDeployer} from "./../src/CTDeployer.sol";
import {CTProjectOwner} from "./../src/CTProjectOwner.sol";
import {CTPublisher} from "./../src/CTPublisher.sol";
import {CoreDeployment, CoreDeploymentLib} from "./helpers/CoreDeploymentLib.sol";

contract DeployScript is Script, Sphinx {
    /// @notice Tracks the core deployment for the current chain.
    CoreDeployment core;
    /// @notice Tracks the 721 hook deployment for the current chain.
    Hook721Deployment hook;
    /// @notice Tracks the sucker deployment for the current chain.
    SuckerDeployment suckers;

    /// @notice Set this to a non-zero value to reuse an existing fee project. Leaving it as 0 deploys a new one.
    uint256 private feeProjectId = 0;

    /// @notice CREATE2 salts used to deploy the Croptop contracts.
    bytes32 private constant _PUBLISHER_SALT = "_PUBLISHER_SALTV6_";
    bytes32 private constant _DEPLOYER_SALT = "_DEPLOYER_SALTV6_";
    bytes32 private constant _PROJECT_OWNER_SALT = "_PROJECT_OWNER_SALTV6_";
    IPermit2 private constant _PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address private trustedForwarder;

    function configureSphinx() public override {
        sphinxConfig.projectName = "croptop-core-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the core deployment addresses for this chain.
        // We want to do this outside of the `sphinx` modifier.
        core = CoreDeploymentLib.getDeployment(
            vm.envOr("NANA_CORE_DEPLOYMENT_PATH", string("node_modules/@bananapus/core-v6/deployments/"))
        );
        // Get the deployment addresses for the 721 hook contracts for this chain.
        hook = Hook721DeploymentLib.getDeployment(
            vm.envOr("NANA_721_DEPLOYMENT_PATH", string("node_modules/@bananapus/721-hook-v6/deployments/"))
        );
        // Get the deployment addresses for the suckers contracts for this chain.
        suckers = SuckerDeploymentLib.getDeployment(
            vm.envOr("NANA_SUCKERS_DEPLOYMENT_PATH", string("node_modules/@bananapus/suckers-v6/deployments/"))
        );

        // We use the same trusted forwarder as the core deployment.
        trustedForwarder = core.controller.trustedForwarder();

        // Perform the deployment transactions.
        deploy();
    }

    function deploy() public sphinx {
        // Canonical Croptop deployments must bind fees to an explicit fee project. Autodiscovering the first
        // matching publisher by scanning project IDs is unsafe because a preexisting publisher can pin fees to
        // the wrong project forever.
        require(feeProjectId != 0, "explicit fee project id required");

        CTPublisher publisher;
        {
            // Check whether the publisher is already deployed.
            (address _publisher, bool _publisherIsDeployed) = _isDeployed({
                salt: _PUBLISHER_SALT,
                creationCode: type(CTPublisher).creationCode,
                arguments: abi.encode(core.directory, core.permissions, feeProjectId, _PERMIT2, trustedForwarder)
            });

            // Deploy it if it has not been deployed yet.
            publisher = !_publisherIsDeployed
                ? new CTPublisher{salt: _PUBLISHER_SALT}({
                    directory: core.directory,
                    permissions: core.permissions,
                    feeProjectId: feeProjectId,
                    permit2: _PERMIT2,
                    trustedForwarder: trustedForwarder
                })
                : CTPublisher(_publisher);
        }

        CTDeployer deployer;
        {
            // Check whether the deployer is already deployed.
            (address _deployer, bool _deployerIsDeployed) = _isDeployed({
                salt: _DEPLOYER_SALT,
                creationCode: type(CTDeployer).creationCode,
                arguments: abi.encode(
                    core.permissions, core.projects, hook.hookDeployer, publisher, suckers.registry, trustedForwarder
                )
            });

            // Deploy it if it has not been deployed yet.
            deployer = !_deployerIsDeployed
                ? new CTDeployer{salt: _DEPLOYER_SALT}({
                    permissions: core.permissions,
                    projects: core.projects,
                    deployer: hook.hookDeployer,
                    publisher: publisher,
                    suckerRegistry: suckers.registry,
                    trustedForwarder: trustedForwarder
                })
                : CTDeployer(_deployer);
        }

        CTProjectOwner owner;
        {
            // Check whether the project-owner sink is already deployed.
            (address _owner, bool _ownerIsDeployed) = _isDeployed({
                salt: _PROJECT_OWNER_SALT,
                creationCode: type(CTProjectOwner).creationCode,
                arguments: abi.encode(core.permissions, core.projects, publisher)
            });

            // Deploy it if it has not been deployed yet.
            owner = !_ownerIsDeployed
                ? new CTProjectOwner{salt: _PROJECT_OWNER_SALT}({
                    permissions: core.permissions, projects: core.projects, publisher: publisher
                })
                : CTProjectOwner(_owner);
        }
    }

    function _isDeployed(
        bytes32 salt,
        bytes memory creationCode,
        bytes memory arguments
    )
        internal
        view
        returns (address, bool)
    {
        address _deployedTo = vm.computeCreate2Address({
            salt: salt,
            initCodeHash: keccak256(abi.encodePacked(creationCode, arguments)),
            // Arachnid/deterministic-deployment-proxy address.
            deployer: address(0x4e59b44847b379578588920cA78FbF26c0B4956C)
        });

        // Return if code is already present at this address.
        return (_deployedTo, address(_deployedTo).code.length != 0);
    }
}
