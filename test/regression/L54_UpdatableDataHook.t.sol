// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {ICTDeployer} from "../../src/interfaces/ICTDeployer.sol";
import {ICTPublisher} from "../../src/interfaces/ICTPublisher.sol";

/// @title L54_UpdatableDataHook
/// @notice Regression test for L-54: dataHookOf was immutable after deployment.
///         The fix adds a setDataHookOf() function that allows the project owner
///         to update the data hook.
contract L54_UpdatableDataHook is Test {
    CTDeployer deployer;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    ICTPublisher publisher = ICTPublisher(makeAddr("publisher"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));

    address projectOwner = makeAddr("projectOwner");
    address nonOwner = makeAddr("nonOwner");

    uint256 projectId = 42;

    IJBRulesetDataHook originalHook = IJBRulesetDataHook(makeAddr("originalHook"));
    IJBRulesetDataHook newHook = IJBRulesetDataHook(makeAddr("newHook"));

    function setUp() public {
        // Mock the permissions.setPermissionsFor calls in the constructor.
        vm.mockCall(address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), "");

        deployer = new CTDeployer(permissions, projects, hookDeployer, publisher, suckerRegistry, address(0));

        // Mock project ownership (ownerOf is from IERC721).
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(projectOwner)
        );
    }

    /// @notice The project owner should be able to update the data hook.
    function test_ownerCanSetDataHook() public {
        // Verify initial state is zero.
        assertEq(address(deployer.dataHookOf(projectId)), address(0), "initial data hook should be zero");

        // Owner sets the data hook.
        vm.prank(projectOwner);
        deployer.setDataHookOf(projectId, originalHook);

        assertEq(
            address(deployer.dataHookOf(projectId)), address(originalHook), "data hook should be set to originalHook"
        );

        // Owner updates the data hook.
        vm.prank(projectOwner);
        deployer.setDataHookOf(projectId, newHook);

        assertEq(address(deployer.dataHookOf(projectId)), address(newHook), "data hook should be updated to newHook");
    }

    /// @notice A non-owner should not be able to set the data hook.
    function test_nonOwnerCannotSetDataHook() public {
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(CTDeployer.CTDeployer_Unauthorized.selector, projectId, nonOwner));
        deployer.setDataHookOf(projectId, newHook);
    }

    /// @notice setDataHookOf should emit a SetDataHook event.
    function test_setDataHookEmitsEvent() public {
        vm.prank(projectOwner);
        vm.expectEmit(true, false, false, true);
        emit ICTDeployer.SetDataHook(projectId, newHook, projectOwner);
        deployer.setDataHookOf(projectId, newHook);
    }
}
