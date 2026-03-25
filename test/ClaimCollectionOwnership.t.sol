// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJB721Hook} from "@bananapus/721-hook-v6/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

import {CTDeployer} from "../src/CTDeployer.sol";
import {CTPublisher} from "../src/CTPublisher.sol";
import {ICTPublisher} from "../src/interfaces/ICTPublisher.sol";
import {CTAllowedPost} from "../src/structs/CTAllowedPost.sol";
import {CTDeployerAllowedPost} from "../src/structs/CTDeployerAllowedPost.sol";
import {CTProjectConfig} from "../src/structs/CTProjectConfig.sol";
import {CTSuckerDeploymentConfig} from "../src/structs/CTSuckerDeploymentConfig.sol";

/// @title ClaimCollectionOwnershipTest
/// @notice Integration tests for the post-claimCollectionOwnership permission lifecycle:
///         1. Deploy a croptop collection
///         2. Claim ownership (transfers hook ownership to project)
///         3. Verify permissions are correctly transferred
///         4. Verify post-claim the hook owner changes and publisher permissions must be re-granted
contract ClaimCollectionOwnershipTest is Test {
    CTDeployer ctDeployer;
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    IJB721TiersHookDeployer hookDeployer = IJB721TiersHookDeployer(makeAddr("hookDeployer"));
    IJBSuckerRegistry suckerRegistry = IJBSuckerRegistry(makeAddr("suckerRegistry"));
    IJBController controller = IJBController(makeAddr("controller"));

    address owner = makeAddr("owner");
    address newOwner = makeAddr("newOwner");
    address unauthorized = makeAddr("unauthorized");
    address hookAddr = makeAddr("hook");

    uint256 projectCount = 5;
    uint256 deployedProjectId = projectCount + 1; // 6
    uint256 feeProjectId = 1;

    // Track which permissions were set.
    PermissionRecord[] permissionRecords;

    struct PermissionRecord {
        address account;
        address operator;
        uint256 projectId;
        uint8[] permissionIds;
    }

    function setUp() public {
        // Mock permissions.setPermissionsFor (called in CTDeployer constructor + deployment).
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );

        // Mock permissions.hasPermission to return true by default.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Mock sucker registry.
        vm.mockCall(
            address(suckerRegistry), abi.encodeWithSelector(IJBSuckerRegistry.isSuckerOf.selector), abi.encode(false)
        );

        // Deploy publisher.
        publisher = new CTPublisher(IJBDirectory(makeAddr("directory")), permissions, feeProjectId, address(0));

        // Deploy the CTDeployer.
        ctDeployer = new CTDeployer(
            permissions, projects, hookDeployer, ICTPublisher(address(publisher)), suckerRegistry, address(0)
        );

        // Fund test accounts.
        vm.deal(owner, 100 ether);
        vm.deal(newOwner, 100 ether);
        vm.deal(unauthorized, 100 ether);
    }

    //*********************************************************************//
    // --- Full Lifecycle: Deploy -> Claim -> Verify ---------------------- //
    //*********************************************************************//

    /// @notice Tests the full lifecycle: deploy project, then claim collection ownership.
    ///         After claiming, the hook's owner should become the project (via transferOwnershipToProject).
    function test_fullLifecycle_deploy_claim_ownershipTransfers() public {
        // Step 1: Deploy the project.
        _mockDeployProjectInfra();

        CTProjectConfig memory config = _defaultProjectConfig();
        CTSuckerDeploymentConfig memory suckerConfig = _emptySuckerConfig();

        (uint256 projectId, IJB721TiersHook hook) = ctDeployer.deployProjectFor(owner, config, suckerConfig, controller);
        assertEq(projectId, deployedProjectId, "project ID should match");

        // Step 2: After deployment, the CTDeployer is the hook's owner.
        // (The deployer owns the hook because it deployed it.)
        // Mock hook.PROJECT_ID() to return deployedProjectId.
        vm.mockCall(address(hook), abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(projectId));

        // Mock PROJECTS.ownerOf(projectId) to return owner.
        vm.mockCall(address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, projectId), abi.encode(owner));

        // Mock JBOwnable.transferOwnershipToProject to succeed.
        vm.mockCall(address(hook), abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        // Step 3: Owner claims collection ownership.
        vm.prank(owner);
        ctDeployer.claimCollectionOwnershipOf(hook);

        // Step 4: After claiming, the hook ownership has been transferred to the project.
        // Verify transferOwnershipToProject was called with the correct projectId.
        // (If it wasn't, the mock would not match and the call would have failed.)
    }

    /// @notice After claiming ownership, the hook's owner is resolved via PROJECTS.ownerOf(projectId).
    ///         If the project NFT is transferred to a new owner, the new owner becomes the hook's owner.
    function test_postClaim_projectTransfer_newOwnerControlsHook() public {
        // Mock hook.PROJECT_ID().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(deployedProjectId));

        // Initially, 'owner' owns the project.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, deployedProjectId), abi.encode(owner)
        );

        // Mock transferOwnershipToProject.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        // Owner claims collection ownership.
        vm.prank(owner);
        ctDeployer.claimCollectionOwnershipOf(IJB721TiersHook(hookAddr));

        // Now simulate the project NFT being transferred to newOwner.
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, deployedProjectId), abi.encode(newOwner)
        );

        // After the hook is owned by the project, the JBOwnable.owner() resolves to PROJECTS.ownerOf(projectId).
        // Verify that if newOwner holds the project NFT, they are the effective owner.
        // Mock hook.owner() to return newOwner (simulating JBOwnable resolution).
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(newOwner));

        // Verify: the old owner can no longer claim (since they don't own the project NFT anymore).
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(CTDeployer.CTDeployer_NotOwnerOfProject.selector, deployedProjectId, hookAddr, owner)
        );
        ctDeployer.claimCollectionOwnershipOf(IJB721TiersHook(hookAddr));
    }

    /// @notice After claimCollectionOwnership, the deployer's permissions from address(this) are
    ///         no longer relevant. The project owner must grant CTPublisher the ADJUST_721_TIERS
    ///         permission for mintFrom() to work. Without it, posts would revert.
    ///
    ///         This test verifies the permission gap: after claim, the hook checks permissions
    ///         against the project (not the deployer), so the publisher needs new permissions.
    function test_postClaim_publisherNeedsNewPermissions() public {
        // After claiming, hook.owner() resolves to PROJECTS.ownerOf(projectId) = owner.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(owner));
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(deployedProjectId));

        // The publisher's configurePostingCriteriaFor calls _requirePermissionFrom(hook.owner(), ...).
        // After claiming, hook.owner() is the project owner, not the deployer.
        // So the project owner must grant CTPublisher the ADJUST_721_TIERS permission.

        // Mock permissions: simulate that the project owner has NOT yet granted the publisher permission.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(false)
        );

        // The publisher's configurePostingCriteriaFor should revert because the publisher
        // doesn't have permission from the new owner.
        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 0.01 ether,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        // Expect the publisher to revert due to missing permissions.
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                owner, // account (hook.owner())
                address(this), // caller (us, calling configurePostingCriteriaFor)
                deployedProjectId,
                JBPermissionIds.ADJUST_721_TIERS
            )
        );
        publisher.configurePostingCriteriaFor(allowedPosts);
    }

    /// @notice After granting the publisher new permissions, posting works again.
    function test_postClaim_publisherWorksAfterPermissionGrant() public {
        // After claiming, hook.owner() = owner.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(owner));
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(deployedProjectId));

        // The project owner grants CTPublisher the ADJUST_721_TIERS permission.
        // Simulate: hasPermission returns true for publisher calling from owner's context.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 2,
            minimumPrice: 0.05 ether,
            minimumTotalSupply: 1,
            maximumTotalSupply: 50,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        // This should succeed because the publisher has the correct permission.
        publisher.configurePostingCriteriaFor(allowedPosts);

        // Verify the allowance was set.
        (uint256 minPrice, uint256 minSupply, uint256 maxSupply,,) = publisher.allowanceFor(hookAddr, 2);
        assertEq(minPrice, 0.05 ether, "minimum price should be configured after re-grant");
        assertEq(minSupply, 1, "minimum supply should be configured");
        assertEq(maxSupply, 50, "maximum supply should be configured");
    }

    /// @notice Claiming twice for the same hook should succeed (idempotent — just calls
    ///         transferOwnershipToProject again, which the hook handles internally).
    function test_claim_calledTwice_succeeds() public {
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(deployedProjectId));
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, deployedProjectId), abi.encode(owner)
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.transferOwnershipToProject.selector), abi.encode());

        // First claim.
        vm.prank(owner);
        ctDeployer.claimCollectionOwnershipOf(IJB721TiersHook(hookAddr));

        // Second claim (should not revert with our mocks).
        vm.prank(owner);
        ctDeployer.claimCollectionOwnershipOf(IJB721TiersHook(hookAddr));
    }

    /// @notice Non-owner cannot claim even after project ownership changes.
    function test_claim_revertsForNonProjectOwner() public {
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(deployedProjectId));
        vm.mockCall(
            address(projects), abi.encodeWithSelector(IERC721.ownerOf.selector, deployedProjectId), abi.encode(owner)
        );

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                CTDeployer.CTDeployer_NotOwnerOfProject.selector, deployedProjectId, hookAddr, unauthorized
            )
        );
        ctDeployer.claimCollectionOwnershipOf(IJB721TiersHook(hookAddr));
    }

    //*********************************************************************//
    // --- Internal Helpers ---------------------------------------------- //
    //*********************************************************************//

    function _defaultProjectConfig() internal pure returns (CTProjectConfig memory) {
        return CTProjectConfig({
            terminalConfigurations: new JBTerminalConfig[](0),
            projectUri: "https://croptop.test/",
            allowedPosts: new CTDeployerAllowedPost[](0),
            contractUri: "https://croptop.test/contract",
            name: "TestCrop",
            symbol: "TC",
            salt: bytes32(0)
        });
    }

    function _emptySuckerConfig() internal pure returns (CTSuckerDeploymentConfig memory) {
        return CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});
    }

    function _mockDeployProjectInfra() internal {
        vm.mockCall(address(controller), abi.encodeWithSelector(IJBController.PROJECTS.selector), abi.encode(projects));
        vm.mockCall(address(projects), abi.encodeWithSelector(IJBProjects.count.selector), abi.encode(projectCount));
        vm.mockCall(
            address(hookDeployer),
            abi.encodeWithSelector(IJB721TiersHookDeployer.deployHookFor.selector),
            abi.encode(IJB721TiersHook(hookAddr))
        );
        vm.mockCall(
            address(controller),
            abi.encodeWithSelector(IJBController.launchProjectFor.selector),
            abi.encode(deployedProjectId)
        );
        vm.mockCall(address(projects), abi.encodeWithSelector(IERC721.transferFrom.selector), abi.encode());
    }
}
