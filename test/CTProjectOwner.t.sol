// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";

import {CTProjectOwner} from "../src/CTProjectOwner.sol";
import {ICTPublisher} from "../src/interfaces/ICTPublisher.sol";

/// @notice Unit tests for CTProjectOwner.
contract CTProjectOwnerTest is Test {
    CTProjectOwner projectOwner;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBProjects projects = IJBProjects(makeAddr("projects"));
    ICTPublisher publisher = ICTPublisher(makeAddr("publisher"));

    address operator = makeAddr("operator");
    address from = makeAddr("from");

    function setUp() public {
        projectOwner = new CTProjectOwner(permissions, projects, publisher);

        // Mock setPermissionsFor to succeed by default.
        vm.mockCall(
            address(permissions), abi.encodeWithSelector(IJBPermissions.setPermissionsFor.selector), abi.encode()
        );
    }

    //*********************************************************************//
    // --- Constructor --------------------------------------------------- //
    //*********************************************************************//

    /// @notice Verify that the constructor sets all three immutables correctly.
    function test_constructor() public {
        assertEq(address(projectOwner.PERMISSIONS()), address(permissions));
        assertEq(address(projectOwner.PROJECTS()), address(projects));
        assertEq(address(projectOwner.PUBLISHER()), address(publisher));
    }

    //*********************************************************************//
    // --- onERC721Received ---------------------------------------------- //
    //*********************************************************************//

    /// @notice When PROJECTS sends a project NFT, the contract grants ADJUST_721_TIERS permission to PUBLISHER and
    /// returns the correct selector.
    function test_onERC721Received_fromProjects_grantsPermission() public {
        uint256 tokenId = 42;

        // Build the expected arguments for setPermissionsFor.
        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.ADJUST_721_TIERS;

        vm.expectCall(
            address(permissions),
            abi.encodeCall(
                IJBPermissions.setPermissionsFor,
                (
                    address(projectOwner),
                    JBPermissionsData({
                        operator: address(publisher),
                        // forge-lint: disable-next-line(unsafe-typecast)
                        projectId: uint64(tokenId), // safe: mirrors CTProjectOwner.onERC721Received
                        permissionIds: permissionIds
                    })
                )
            )
        );

        // Call onERC721Received as if PROJECTS sent the NFT.
        vm.prank(address(projects));
        bytes4 retval = projectOwner.onERC721Received(operator, from, tokenId, "");

        assertEq(retval, IERC721Receiver.onERC721Received.selector);
    }

    /// @notice Calling onERC721Received from any address other than PROJECTS must revert.
    function test_onERC721Received_fromNonProjects_reverts() public {
        address notProjects = makeAddr("notProjects");

        vm.prank(notProjects);
        vm.expectRevert();
        projectOwner.onERC721Received(operator, from, 1, "");
    }

    /// @notice The permission is set with projectId equal to uint64(tokenId).
    function test_onERC721Received_correctProjectId() public {
        uint256 tokenId = type(uint64).max; // Use a large tokenId to confirm truncation.

        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.ADJUST_721_TIERS;

        vm.expectCall(
            address(permissions),
            abi.encodeCall(
                IJBPermissions.setPermissionsFor,
                (
                    address(projectOwner),
                    JBPermissionsData({
                        operator: address(publisher),
                        // forge-lint: disable-next-line(unsafe-typecast)
                        projectId: uint64(tokenId), // safe: mirrors CTProjectOwner.onERC721Received
                        permissionIds: permissionIds
                    })
                )
            )
        );

        vm.prank(address(projects));
        projectOwner.onERC721Received(operator, from, tokenId, "");
    }

    /// @notice Transferring multiple different project NFTs sets permissions for each one independently.
    function test_onERC721Received_multipleProjects() public {
        uint256 tokenId1 = 10;
        uint256 tokenId2 = 99;

        uint8[] memory permissionIds = new uint8[](1);
        permissionIds[0] = JBPermissionIds.ADJUST_721_TIERS;

        // Expect the first call with tokenId1.
        vm.expectCall(
            address(permissions),
            abi.encodeCall(
                IJBPermissions.setPermissionsFor,
                (
                    address(projectOwner),
                    JBPermissionsData({
                        operator: address(publisher),
                        // forge-lint: disable-next-line(unsafe-typecast)
                        projectId: uint64(tokenId1), // safe: mirrors CTProjectOwner.onERC721Received
                        permissionIds: permissionIds
                    })
                )
            )
        );

        vm.prank(address(projects));
        bytes4 retval1 = projectOwner.onERC721Received(operator, from, tokenId1, "");
        assertEq(retval1, IERC721Receiver.onERC721Received.selector);

        // Expect the second call with tokenId2.
        vm.expectCall(
            address(permissions),
            abi.encodeCall(
                IJBPermissions.setPermissionsFor,
                (
                    address(projectOwner),
                    JBPermissionsData({
                        operator: address(publisher),
                        // forge-lint: disable-next-line(unsafe-typecast)
                        projectId: uint64(tokenId2), // safe: mirrors CTProjectOwner.onERC721Received
                        permissionIds: permissionIds
                    })
                )
            )
        );

        vm.prank(address(projects));
        bytes4 retval2 = projectOwner.onERC721Received(operator, from, tokenId2, "");
        assertEq(retval2, IERC721Receiver.onERC721Received.selector);
    }

    /// @notice Fuzz: any tokenId from PROJECTS succeeds and returns the correct selector.
    function test_onERC721Received_fuzz(uint256 tokenId) public {
        vm.prank(address(projects));
        bytes4 retval = projectOwner.onERC721Received(operator, from, tokenId, "");
        assertEq(retval, IERC721Receiver.onERC721Received.selector);
    }

    /// @notice Fuzz: any non-PROJECTS sender reverts.
    function test_onERC721Received_fuzz_nonProjects_reverts(address sender) public {
        vm.assume(sender != address(projects));

        vm.prank(sender);
        vm.expectRevert();
        projectOwner.onERC721Received(operator, from, 1, "");
    }
}
