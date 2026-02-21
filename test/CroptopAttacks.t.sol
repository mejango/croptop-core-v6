// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v5/src/interfaces/IJBTerminal.sol";
import {IJBOwnable} from "@bananapus/ownable-v5/src/interfaces/IJBOwnable.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v5/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v5/src/interfaces/IJB721TiersHookStore.sol";
import {IJB721Hook} from "@bananapus/721-hook-v5/src/interfaces/IJB721Hook.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v5/src/structs/JB721TierConfig.sol";
import {JBConstants} from "@bananapus/core-v5/src/libraries/JBConstants.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v5/src/JBPermissionIds.sol";

import {CTPublisher} from "../src/CTPublisher.sol";
import {CTAllowedPost} from "../src/structs/CTAllowedPost.sol";
import {CTPost} from "../src/structs/CTPost.sol";

/// @title CroptopAttacks
/// @notice Adversarial security tests for CTPublisher focusing on mintFrom edge cases,
///         allowlist bypasses, and input validation.
contract CroptopAttacks is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr = makeAddr("hookStore");
    address terminalAddr = makeAddr("terminal");
    address poster = makeAddr("poster");
    address unauthorized = makeAddr("unauthorized");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, feeProjectId, address(0));

        // Mock hook.owner().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));
        // Mock hook.PROJECT_ID().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(hookProjectId));
        // Mock hook.STORE().
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.STORE.selector), abi.encode(hookStoreAddr));

        // Mock permissions to return true by default.
        vm.mockCall(
            address(permissions),
            abi.encodeWithSelector(IJBPermissions.hasPermission.selector),
            abi.encode(true)
        );

        // Fund test accounts so they can send ETH with mintFrom.
        vm.deal(poster, 100 ether);
        vm.deal(unauthorized, 100 ether);
    }

    /// @dev Configure a standard category for testing.
    function _configureCategory(uint24 category, uint104 minPrice, uint32 minSupply, uint32 maxSupply) internal {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: category,
            minimumPrice: minPrice,
            minimumTotalSupply: minSupply,
            maximumTotalSupply: maxSupply,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);
    }

    /// @dev Configure a category with an allowlist.
    function _configureCategoryWithAllowlist(uint24 category, address[] memory allowed) internal {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: category,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            allowedAddresses: allowed
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);
    }

    // =========================================================================
    // Test 1: Post to unconfigured category — should revert
    // =========================================================================
    function test_mintFrom_unconfiguredCategory_reverts() public {
        // Category 999 is not configured.
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("test-content"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 999
        });

        // Mock adjustTiers (won't be reached if validation works).
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.1 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 2: Post with price below minimum — should revert
    // =========================================================================
    function test_mintFrom_belowMinPrice_reverts() public {
        _configureCategory(5, 0.1 ether, 1, 100); // min price = 0.1 ETH

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("cheap-content"),
            totalSupply: 10,
            price: 0.01 ether, // Below minimum!
            category: 5
        });

        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 3: Post with supply above maximum — should revert
    // =========================================================================
    function test_mintFrom_exceedsMaxSupply_reverts() public {
        _configureCategory(5, 0, 1, 50); // max supply = 50

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("big-supply"),
            totalSupply: 100, // Above maximum!
            price: 0.01 ether,
            category: 5
        });

        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 4: Post with supply below minimum — should revert
    // =========================================================================
    function test_mintFrom_belowMinSupply_reverts() public {
        _configureCategory(5, 0, 10, 100); // min supply = 10

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("small-supply"),
            totalSupply: 5, // Below minimum!
            price: 0.01 ether,
            category: 5
        });

        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 5: Allowlist bypass — non-allowed address posts to restricted category
    // =========================================================================
    function test_mintFrom_allowlistBypass_reverts() public {
        address[] memory allowed = new address[](1);
        allowed[0] = poster; // Only `poster` is allowed.

        _configureCategoryWithAllowlist(7, allowed);

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("sneaky-content"),
            totalSupply: 10,
            price: 0.01 ether,
            category: 7
        });

        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());

        // Unauthorized caller tries to post.
        vm.prank(unauthorized);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, unauthorized, unauthorized, "", "");
    }

    // =========================================================================
    // Test 6: Zero IPFS URI — should revert
    // =========================================================================
    function test_mintFrom_zeroIPFSUri_reverts() public {
        _configureCategory(5, 0, 1, 100);

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: bytes32(0), // Zero URI!
            totalSupply: 10,
            price: 0.01 ether,
            category: 5
        });

        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());

        vm.prank(poster);
        vm.expectRevert();
        publisher.mintFrom{value: 0.01 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 7: Configure with zero minSupply disables category
    // =========================================================================
    function test_configure_zeroMinSupply_reverts() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 5,
            minimumPrice: 0,
            minimumTotalSupply: 0, // Zero!
            maximumTotalSupply: 100,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        vm.expectRevert(CTPublisher.CTPublisher_ZeroTotalSupply.selector);
        publisher.configurePostingCriteriaFor(posts);
    }

    // =========================================================================
    // Test 8: Configure without permission — should revert
    // =========================================================================
    function test_configure_noPermission_reverts() public {
        // Mock permissions to return false.
        vm.mockCall(
            address(permissions),
            abi.encodeWithSelector(IJBPermissions.hasPermission.selector),
            abi.encode(false)
        );

        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            allowedAddresses: new address[](0)
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        publisher.configurePostingCriteriaFor(posts);
    }
}
