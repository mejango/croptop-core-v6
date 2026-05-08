// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBOwnable} from "@bananapus/ownable-v6/src/JBOwnable.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {ICTPublisher} from "../../src/interfaces/ICTPublisher.sol";

/// @notice Tracks all setPermissionsFor calls to verify permission revocation.
contract PermTrackingPermissions is IJBPermissions {
    struct PermCall {
        address account;
        address operator;
        uint64 projectId;
        uint8[] permissionIds;
    }

    PermCall[] public calls;

    // forge-lint: disable-next-line(mixed-case-function)
    function WILDCARD_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function permissionsOf(address, address, uint256) external pure returns (uint256) {
        return type(uint256).max; // All perms granted for simplicity
    }

    function hasPermission(address, address, uint256, uint256, bool, bool) external pure returns (bool) {
        return true;
    }

    function hasPermissions(address, address, uint256, uint256[] calldata, bool, bool) external pure returns (bool) {
        return true;
    }

    function setPermissionsFor(address account, JBPermissionsData calldata data) external {
        calls.push(
            PermCall({
                account: account, operator: data.operator, projectId: data.projectId, permissionIds: data.permissionIds
            })
        );
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function getCall(uint256 idx) external view returns (address, address, uint64, uint256) {
        PermCall storage c = calls[idx];
        return (c.account, c.operator, c.projectId, c.permissionIds.length);
    }
}

/// @notice Mock hook that exposes PROJECT_ID and a transferOwnershipToProject function.
contract PermMockHook {
    uint256 public immutable PROJECT_ID;
    bool public ownershipTransferred;

    constructor(uint256 projectId) {
        PROJECT_ID = projectId;
    }

    /// @dev Simulates JBOwnable.transferOwnershipToProject
    function transferOwnershipToProject(uint256) external {
        ownershipTransferred = true;
    }
}

/// @notice Mock projects contract.
contract PermMockProjects {
    mapping(uint256 => address) public owners;

    function ownerOf(uint256 projectId) external view returns (address) {
        return owners[projectId];
    }

    function setOwner(uint256 projectId, address owner_) external {
        owners[projectId] = owner_;
    }
}

/// @notice Regression test for bug AP — `claimCollectionOwnershipOf` must revoke deployer-scoped permissions.
/// @dev Before the fix, `claimCollectionOwnershipOf` did not revoke the deployer-scoped permissions granted at
///      deployment time, leading to stale permission leakage. The fix passes an empty `permissionIds` array to
///      `setPermissionsFor`, which zeroes out the operator's packed permissions for that project scope.
contract PermissionLifecycleOnTransferTest is Test {
    PermTrackingPermissions permissions;
    PermMockProjects projects;
    PermMockHook hook;

    CTDeployer deployer;

    address ownerA = address(0xA);
    uint256 constant PROJECT_ID = 42;

    function setUp() public {
        permissions = new PermTrackingPermissions();
        projects = new PermMockProjects();
        projects.setOwner(PROJECT_ID, ownerA);

        hook = new PermMockHook(PROJECT_ID);

        // Deploy CTDeployer with mocked dependencies (only permissions and projects matter for this test).
        deployer = new CTDeployer(
            permissions,
            IJBProjects(address(projects)),
            IJB721TiersHookDeployer(address(0)),
            ICTPublisher(address(0)),
            IJBSuckerRegistry(address(0)),
            address(0)
        );
    }

    /// @notice After claimCollectionOwnershipOf, the deployer-scoped permissions for the caller are revoked.
    function test_claimOwnership_revokesDeployerScopedPermissions() public {
        // Record how many setPermissionsFor calls have been made before claim (constructor makes one).
        uint256 callsBefore = permissions.callCount();

        // ownerA calls claimCollectionOwnershipOf
        vm.prank(ownerA);
        deployer.claimCollectionOwnershipOf(IJB721TiersHook(address(hook)));

        // Should have made one new setPermissionsFor call
        uint256 callsAfter = permissions.callCount();
        assertEq(callsAfter, callsBefore + 1, "should have made exactly one new setPermissionsFor call");

        // Inspect the revocation call
        uint256 revokeIdx = callsAfter - 1;
        (address account, address operator, uint64 projectId, uint256 permLen) = permissions.getCall(revokeIdx);

        assertEq(account, address(deployer), "revocation should be on deployer's behalf");
        assertEq(operator, ownerA, "revocation should target the project owner");
        assertEq(projectId, uint64(PROJECT_ID), "revocation should scope to the project ID");
        assertEq(permLen, 0, "revocation should pass empty permissionIds (clearing all perms)");

        // Verify ownership was transferred
        assertTrue(hook.ownershipTransferred(), "hook ownership should have been transferred");
    }

    /// @notice Non-owner cannot call claimCollectionOwnershipOf.
    function test_claimOwnership_revertsForNonOwner() public {
        address notOwner = address(0xBAD);

        vm.prank(notOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                CTDeployer.CTDeployer_NotOwnerOfProject.selector, PROJECT_ID, address(hook), notOwner
            )
        );
        deployer.claimCollectionOwnershipOf(IJB721TiersHook(address(hook)));
    }
}
