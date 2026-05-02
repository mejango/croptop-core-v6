// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {ICTPublisher} from "../../src/interfaces/ICTPublisher.sol";
import {CTSuckerDeploymentConfig} from "../../src/structs/CTSuckerDeploymentConfig.sol";

contract NemesisPermissions is IJBPermissions {
    mapping(
        address operator
            => mapping(address account => mapping(uint256 projectId => mapping(uint256 permissionId => bool)))
    ) internal _permission;

    function WILDCARD_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function setPermission(
        address operator,
        address account,
        uint256 projectId,
        uint256 permissionId,
        bool value
    )
        external
    {
        _permission[operator][account][projectId][permissionId] = value;
    }

    function hasPermission(
        address operator,
        address account,
        uint256 projectId,
        uint256 permissionId,
        bool,
        bool includeWildcardProjectId
    )
        external
        view
        returns (bool)
    {
        return _permission[operator][account][projectId][permissionId]
            || (includeWildcardProjectId && _permission[operator][account][0][permissionId]);
    }

    function hasPermissions(
        address operator,
        address account,
        uint256 projectId,
        uint256[] calldata permissionIds,
        bool includeRoot,
        bool includeWildcardProjectId
    )
        external
        view
        returns (bool)
    {
        for (uint256 i; i < permissionIds.length; i++) {
            if (!this.hasPermission(
                    operator, account, projectId, permissionIds[i], includeRoot, includeWildcardProjectId
                )) {
                return false;
            }
        }
        return true;
    }

    function permissionsOf(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function setPermissionsFor(address account, JBPermissionsData calldata permissionsData) external {
        for (uint256 i; i < permissionsData.permissionIds.length; i++) {
            _permission[
                permissionsData.operator
            ][account][permissionsData.projectId][permissionsData.permissionIds[i]] = true;
        }
    }
}

contract NemesisProjects {
    mapping(uint256 projectId => address owner) internal _ownerOf;

    function setOwner(uint256 projectId, address owner) external {
        _ownerOf[projectId] = owner;
    }

    function ownerOf(uint256 projectId) external view returns (address) {
        return _ownerOf[projectId];
    }
}

contract NemesisPermissionCheckingSuckerRegistry {
    error RegistryUnauthorized(address operator, address account, uint256 projectId);

    NemesisPermissions internal immutable _permissions;
    NemesisProjects internal immutable _projects;

    constructor(NemesisPermissions permissions, NemesisProjects projects) {
        _permissions = permissions;
        _projects = projects;
    }

    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function deploySuckersFor(
        uint256 projectId,
        bytes32,
        JBSuckerDeployerConfig[] calldata
    )
        external
        view
        returns (address[] memory suckers)
    {
        address owner = _projects.ownerOf(projectId);
        bool authorized = msg.sender == owner
            || _permissions.hasPermission(msg.sender, owner, projectId, JBPermissionIds.DEPLOY_SUCKERS, true, true);
        if (!authorized) revert RegistryUnauthorized(msg.sender, owner, projectId);
        return new address[](0);
    }
}

contract CodexNemesisSuckerWrapperTest is Test {
    function testProjectOwnerCannotUseCTDeployerDeploySuckersWithoutGrantingTheWrapper() external {
        uint256 projectId = 7;
        address owner = address(0xA11CE);

        NemesisPermissions permissions = new NemesisPermissions();
        NemesisProjects projects = new NemesisProjects();
        projects.setOwner(projectId, owner);

        NemesisPermissionCheckingSuckerRegistry registry =
            new NemesisPermissionCheckingSuckerRegistry(permissions, projects);

        CTDeployer deployer = new CTDeployer({
            permissions: permissions,
            projects: IJBProjects(address(projects)),
            deployer: IJB721TiersHookDeployer(address(0xBEEF)),
            publisher: ICTPublisher(address(0xCAFE)),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            trustedForwarder: address(0)
        });

        CTSuckerDeploymentConfig memory config = CTSuckerDeploymentConfig({
            deployerConfigurations: new JBSuckerDeployerConfig[](0),
            // forge-lint: disable-next-line(unsafe-typecast)
            salt: bytes32("salt")
        });

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CTDeployer.CTDeployer_SuckerDeploymentPermissionRequired.selector, projectId, owner)
        );
        deployer.deploySuckersFor(projectId, config);

        permissions.setPermission(address(deployer), owner, projectId, JBPermissionIds.DEPLOY_SUCKERS, true);

        vm.prank(owner);
        address[] memory suckers = deployer.deploySuckersFor(projectId, config);
        assertEq(suckers.length, 0);
    }
}
