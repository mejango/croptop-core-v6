// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";

import {ICTPublisher} from "./ICTPublisher.sol";
import {CTSuckerDeploymentConfig} from "../structs/CTSuckerDeploymentConfig.sol";
import {CTProjectConfig} from "../structs/CTProjectConfig.sol";

interface ICTDeployer {
    /// @notice The contract that mints ERC-721s representing Juicebox project ownership.
    /// @return The projects contract.
    function PROJECTS() external view returns (IJBProjects);

    /// @notice The deployer used to launch tiered ERC-721 hook collections.
    /// @return The hook deployer contract.
    function DEPLOYER() external view returns (IJB721TiersHookDeployer);

    /// @notice The Croptop publisher that manages posting criteria and minting.
    /// @return The publisher contract.
    function PUBLISHER() external view returns (ICTPublisher);

    /// @notice Deploy a simple Juicebox project configured to receive posts from Croptop templates.
    /// @param owner The address that will own the project after deployment.
    /// @param projectConfig The configuration for the project, including name, symbol, and allowed posts.
    /// @param suckerDeploymentConfiguration The configuration for cross-chain suckers to deploy.
    /// @param controller The controller that will manage the project.
    /// @return projectId The ID of the newly created project.
    /// @return hook The tiered ERC-721 hook that was deployed for the project.
    function deployProjectFor(
        address owner,
        CTProjectConfig calldata projectConfig,
        CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        external
        returns (uint256 projectId, IJB721TiersHook hook);

    /// @notice Claim ownership of a tiered ERC-721 hook collection by transferring it to the project.
    /// @param hook The hook to claim ownership of. The caller must own the project the hook belongs to.
    function claimCollectionOwnershipOf(IJB721TiersHook hook) external;

    /// @notice Deploy new suckers for an existing project.
    /// @param projectId The ID of the project to deploy suckers for.
    /// @param suckerDeploymentConfiguration The suckers to set up for the project.
    /// @return suckers The addresses of the deployed suckers.
    function deploySuckersFor(
        uint256 projectId,
        CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (address[] memory suckers);
}
