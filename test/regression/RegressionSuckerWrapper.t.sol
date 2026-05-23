// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSucker} from "@bananapus/suckers-v6/src/interfaces/IJBSucker.sol";
import {IJBSuckerDeployer} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBTokenMapping} from "@bananapus/suckers-v6/src/structs/JBTokenMapping.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {ICTPublisher} from "../../src/interfaces/ICTPublisher.sol";
import {CTSuckerDeploymentConfig} from "../../src/structs/CTSuckerDeploymentConfig.sol";

contract RegressionPermissions is IJBPermissions {
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

contract RegressionProjects {
    mapping(uint256 projectId => address owner) internal _ownerOf;

    function setOwner(uint256 projectId, address owner) external {
        _ownerOf[projectId] = owner;
    }

    function ownerOf(uint256 projectId) external view returns (address) {
        return _ownerOf[projectId];
    }
}

contract RegressionPermissionCheckingSuckerRegistry {
    error RegistryUnauthorized(address operator, address account, uint256 projectId);

    RegressionPermissions internal immutable _permissions;
    RegressionProjects internal immutable _projects;

    constructor(RegressionPermissions permissions, RegressionProjects projects) {
        _permissions = permissions;
        _projects = projects;
    }

    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function deploySuckersFor(
        uint256 projectId,
        bytes32,
        JBSuckerDeployerConfig[] calldata configurations
    )
        external
        view
        returns (address[] memory suckers)
    {
        address owner = _projects.ownerOf(projectId);
        bool authorized = msg.sender == owner
            || _permissions.hasPermission(msg.sender, owner, projectId, JBPermissionIds.DEPLOY_SUCKERS, true, true);
        if (!authorized) revert RegistryUnauthorized(msg.sender, owner, projectId);

        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 selfPeer = bytes32(uint256(uint160(address(this))));
        for (uint256 i; i < configurations.length;) {
            bytes32 peer = configurations[i].peer;
            if (peer != bytes32(0) && peer != selfPeer) {
                bool peerAuthorized = msg.sender == owner
                    || _permissions.hasPermission(
                        msg.sender, owner, projectId, JBPermissionIds.SET_SUCKER_PEER, true, true
                    );
                if (!peerAuthorized) revert RegistryUnauthorized(msg.sender, owner, projectId);
            }

            unchecked {
                ++i;
            }
        }

        return new address[](0);
    }
}

contract RegressionSuckerWrapperTest is Test {
    function testProjectOwnerCannotUseCTDeployerDeploySuckersWithoutGrantingTheWrapper() external {
        uint256 projectId = 7;
        address owner = address(0xA11CE);

        RegressionPermissions permissions = new RegressionPermissions();
        RegressionProjects projects = new RegressionProjects();
        projects.setOwner(projectId, owner);

        RegressionPermissionCheckingSuckerRegistry registry =
            new RegressionPermissionCheckingSuckerRegistry(permissions, projects);

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
            abi.encodeWithSelector(
                RegressionPermissionCheckingSuckerRegistry.RegistryUnauthorized.selector,
                address(deployer),
                owner,
                projectId
            )
        );
        deployer.deploySuckersFor(projectId, config);

        permissions.setPermission(address(deployer), owner, projectId, JBPermissionIds.DEPLOY_SUCKERS, true);

        vm.prank(owner);
        address[] memory suckers = deployer.deploySuckersFor(projectId, config);
        assertEq(suckers.length, 0);
    }

    function testDeploySuckersForRequiresOriginalCallerSetPeerPermissionForExplicitPeer() external {
        uint256 projectId = 8;
        address owner = address(0xA11CE);
        address operator = address(0xB0B);

        RegressionPermissions permissions = new RegressionPermissions();
        RegressionProjects projects = new RegressionProjects();
        projects.setOwner(projectId, owner);

        RegressionPermissionCheckingSuckerRegistry registry =
            new RegressionPermissionCheckingSuckerRegistry(permissions, projects);

        CTDeployer deployer = new CTDeployer({
            permissions: permissions,
            projects: IJBProjects(address(projects)),
            deployer: IJB721TiersHookDeployer(address(0xBEEF)),
            publisher: ICTPublisher(address(0xCAFE)),
            suckerRegistry: IJBSuckerRegistry(address(registry)),
            trustedForwarder: address(0)
        });

        permissions.setPermission(operator, owner, projectId, JBPermissionIds.DEPLOY_SUCKERS, true);
        permissions.setPermission(address(deployer), owner, projectId, JBPermissionIds.DEPLOY_SUCKERS, true);
        permissions.setPermission(address(deployer), owner, projectId, JBPermissionIds.SET_SUCKER_PEER, true);

        CTSuckerDeploymentConfig memory config = _explicitPeerConfig(bytes32(uint256(uint160(address(0xFEED)))));

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner,
                operator,
                projectId,
                JBPermissionIds.SET_SUCKER_PEER
            )
        );
        deployer.deploySuckersFor(projectId, config);

        permissions.setPermission(operator, owner, projectId, JBPermissionIds.SET_SUCKER_PEER, true);

        vm.prank(operator);
        address[] memory suckers = deployer.deploySuckersFor(projectId, config);
        assertEq(suckers.length, 0);
    }

    function _explicitPeerConfig(bytes32 peer) internal pure returns (CTSuckerDeploymentConfig memory config) {
        JBSuckerDeployerConfig[] memory deployerConfigurations = new JBSuckerDeployerConfig[](1);
        deployerConfigurations[0] = JBSuckerDeployerConfig({
            deployer: IJBSuckerDeployer(address(0xB0B)), peer: peer, mappings: new JBTokenMapping[](0)
        });

        // forge-lint: disable-next-line(unsafe-typecast)
        return CTSuckerDeploymentConfig({deployerConfigurations: deployerConfigurations, salt: bytes32("salt")});
    }
}
