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
    function PROJECTS() external view returns (IJBProjects);
    function DEPLOYER() external view returns (IJB721TiersHookDeployer);
    function PUBLISHER() external view returns (ICTPublisher);

    function deployProjectFor(
        address owner,
        CTProjectConfig calldata projectConfig,
        CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration,
        IJBController controller
    )
        external
        returns (uint256 projectId, IJB721TiersHook hook);

    function claimCollectionOwnershipOf(IJB721TiersHook hook) external;

    function deploySuckersFor(
        uint256 projectId,
        CTSuckerDeploymentConfig calldata suckerDeploymentConfiguration
    )
        external
        returns (address[] memory suckers);
}
