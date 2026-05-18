// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Hook721Deployment, Hook721DeploymentLib} from "@bananapus/721-hook-v6/script/helpers/Hook721DeploymentLib.sol";
import {CoreDeployment, CoreDeploymentLib} from "@bananapus/core-v6/script/helpers/CoreDeploymentLib.sol";
import {SuckerDeployment, SuckerDeploymentLib} from "@bananapus/suckers-v6/script/helpers/SuckerDeploymentLib.sol";

import {Sphinx} from "@sphinx-labs/contracts/contracts/foundry/SphinxPlugin.sol";
import {Script} from "forge-std/Script.sol";

import {CTDeployer} from "./../src/CTDeployer.sol";
import {CTProjectOwner} from "./../src/CTProjectOwner.sol";
import {CTPublisher} from "./../src/CTPublisher.sol";

contract DeployScript is Script, Sphinx {
    /// @notice tracks the deployment of the core contracts for the chain we are deploying to.
    CoreDeployment core;
    /// @notice tracks the deployment of the 721 hook contracts for the chain we are deploying to.
    Hook721Deployment hook;
    /// @notice tracks the deployment of the sucker contracts for the chain we are deploying to.
    SuckerDeployment suckers;

    /// @notice Set this to a non-zero value to reuse an existing fee project. Leaving it as 0 deploys a new one.
    uint256 private feeProjectId = 0;

    /// @notice the salts that are used to deploy the contracts.
    bytes32 private constant _PUBLISHER_SALT = "_PUBLISHER_SALTV6_";
    bytes32 private constant _DEPLOYER_SALT = "_DEPLOYER_SALTV6_";
    bytes32 private constant _PROJECT_OWNER_SALT = "_PROJECT_OWNER_SALTV6_";
    address private trustedForwarder;

    function configureSphinx() public override {
        sphinxConfig.projectName = "croptop-core-v6";
        sphinxConfig.mainnets = ["ethereum", "optimism", "base", "arbitrum"];
        sphinxConfig.testnets = ["ethereum_sepolia", "optimism_sepolia", "base_sepolia", "arbitrum_sepolia"];
    }

    function run() public {
        // Get the deployment addresses for the nana CORE for this chain.
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
            // Perform the check for the publisher.
            (address _publisher, bool _publisherIsDeployed) = _isDeployed({
                salt: _PUBLISHER_SALT,
                creationCode: type(CTPublisher).creationCode,
                arguments: abi.encode(core.directory, core.permissions, feeProjectId, trustedForwarder)
            });

            // Deploy it if it has not been deployed yet.
            publisher = !_publisherIsDeployed
                ? new CTPublisher{salt: _PUBLISHER_SALT}({
                    directory: core.directory,
                    permissions: core.permissions,
                    feeProjectId: feeProjectId,
                    trustedForwarder: trustedForwarder
                })
                : CTPublisher(_publisher);
        }

        CTDeployer deployer;
        {
            // Perform the check for the publisher.
            (address _deployer, bool _deployerIsDeployed) = _isDeployed({
                salt: _DEPLOYER_SALT,
                creationCode: type(CTDeployer).creationCode,
                arguments: abi.encode(
                    core.permissions, core.projects, hook.hook_deployer, publisher, suckers.registry, trustedForwarder
                )
            });

            // Deploy it if it has not been deployed yet.
            deployer = !_deployerIsDeployed
                ? new CTDeployer{salt: _DEPLOYER_SALT}({
                    permissions: core.permissions,
                    projects: core.projects,
                    deployer: hook.hook_deployer,
                    publisher: publisher,
                    suckerRegistry: suckers.registry,
                    trustedForwarder: trustedForwarder
                })
                : CTDeployer(_deployer);
        }

        CTProjectOwner owner;
        {
            // Perform the check for the publisher.
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
