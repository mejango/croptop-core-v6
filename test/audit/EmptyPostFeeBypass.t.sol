// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

/// @title M24_EmptyPostFeeBypass
/// @notice Verifies that calling mintFrom with an empty posts array reverts,
///         preventing fee-free metadata shadowing via additionalPayMetadata.
contract M24_EmptyPostFeeBypass is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));
    address hookAddr = makeAddr("hook");
    address poster = makeAddr("poster");

    uint256 feeProjectId = 1;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, feeProjectId, address(0));
        vm.deal(poster, 10 ether);
    }

    /// @notice mintFrom with empty posts should revert with CTPublisher_NoPosts.
    function test_revert_emptyPostsArray() public {
        CTPost[] memory emptyPosts = new CTPost[](0);

        vm.prank(poster);
        vm.expectRevert(CTPublisher.CTPublisher_NoPosts.selector);
        publisher.mintFrom{value: 1 ether}(
            IJB721TiersHook(hookAddr), emptyPosts, poster, poster, "", ""
        );
    }

    /// @notice mintFrom with empty posts and crafted additionalPayMetadata should still revert.
    function test_revert_emptyPostsWithMetadata() public {
        CTPost[] memory emptyPosts = new CTPost[](0);

        // Attacker preloads additionalPayMetadata with hook mint metadata.
        bytes memory craftedMetadata = abi.encodePacked(bytes32(uint256(1)), bytes4(0xdeadbeef), uint256(32), uint256(1));

        vm.prank(poster);
        vm.expectRevert(CTPublisher.CTPublisher_NoPosts.selector);
        publisher.mintFrom{value: 1 ether}(
            IJB721TiersHook(hookAddr), emptyPosts, poster, poster, craftedMetadata, ""
        );
    }
}
