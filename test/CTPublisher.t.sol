// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v5/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v5/src/interfaces/IJBDirectory.sol";
import {IJBOwnable} from "@bananapus/ownable-v5/src/interfaces/IJBOwnable.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v5/src/interfaces/IJB721TiersHook.sol";
import {IJB721Hook} from "@bananapus/721-hook-v5/src/interfaces/IJB721Hook.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v5/src/JBPermissionIds.sol";

import {CTPublisher} from "../src/CTPublisher.sol";
import {CTAllowedPost} from "../src/structs/CTAllowedPost.sol";

/// @notice Unit tests for CTPublisher.
contract TestCTPublisher is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address poster = makeAddr("poster");
    address unauthorized = makeAddr("unauthorized");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    function setUp() public {
        publisher = new CTPublisher(directory, permissions, feeProjectId, address(0));

        // Mock hook.owner() for permission checks.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJBOwnable.owner.selector), abi.encode(hookOwner));

        // Mock hook.PROJECT_ID() for permission checks.
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721Hook.PROJECT_ID.selector), abi.encode(hookProjectId));

        // Mock permissions to return true by default.
        vm.mockCall(
            address(permissions),
            abi.encodeWithSelector(IJBPermissions.hasPermission.selector),
            abi.encode(true)
        );
    }

    //*********************************************************************//
    // --- Constructor --------------------------------------------------- //
    //*********************************************************************//

    function test_constructor() public {
        assertEq(address(publisher.DIRECTORY()), address(directory));
        assertEq(publisher.FEE_PROJECT_ID(), feeProjectId);
        assertEq(publisher.FEE_DIVISOR(), 20);
    }

    //*********************************************************************//
    // --- configurePostingCriteriaFor + allowanceFor Round-Trip ---------- //
    //*********************************************************************//

    function test_configureAndReadAllowance() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 5,
            minimumPrice: 0.01 ether,
            minimumTotalSupply: 10,
            maximumTotalSupply: 1000,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (uint256 minPrice, uint256 minSupply, uint256 maxSupply, address[] memory allowed) =
            publisher.allowanceFor(hookAddr, 5);

        assertEq(minPrice, 0.01 ether, "minimum price should match");
        assertEq(minSupply, 10, "minimum supply should match");
        assertEq(maxSupply, 1000, "maximum supply should match");
        assertEq(allowed.length, 0, "no allowlist");
    }

    function test_configureWithAllowlist() public {
        address[] memory allowList = new address[](2);
        allowList[0] = poster;
        allowList[1] = hookOwner;

        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 3,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            allowedAddresses: allowList
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (,,,address[] memory allowed) = publisher.allowanceFor(hookAddr, 3);
        assertEq(allowed.length, 2, "should have 2 allowed addresses");
        assertEq(allowed[0], poster);
        assertEq(allowed[1], hookOwner);
    }

    function test_configureMultipleCategories() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](2);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 100,
            minimumTotalSupply: 5,
            maximumTotalSupply: 50,
            allowedAddresses: new address[](0)
        });
        posts[1] = CTAllowedPost({
            hook: hookAddr,
            category: 2,
            minimumPrice: 200,
            minimumTotalSupply: 10,
            maximumTotalSupply: 100,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (uint256 minPrice1, uint256 minSupply1, uint256 maxSupply1,) = publisher.allowanceFor(hookAddr, 1);
        assertEq(minPrice1, 100);
        assertEq(minSupply1, 5);
        assertEq(maxSupply1, 50);

        (uint256 minPrice2, uint256 minSupply2, uint256 maxSupply2,) = publisher.allowanceFor(hookAddr, 2);
        assertEq(minPrice2, 200);
        assertEq(minSupply2, 10);
        assertEq(maxSupply2, 100);
    }

    //*********************************************************************//
    // --- configurePostingCriteriaFor: Bit Packing Fuzz ----------------- //
    //*********************************************************************//

    function testFuzz_allowanceBitPacking(uint104 minPrice, uint32 minSupply, uint32 maxSupply) public {
        vm.assume(minSupply > 0);
        vm.assume(maxSupply >= minSupply);

        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 0,
            minimumPrice: minPrice,
            minimumTotalSupply: minSupply,
            maximumTotalSupply: maxSupply,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);

        (uint256 readPrice, uint256 readMinSupply, uint256 readMaxSupply,) = publisher.allowanceFor(hookAddr, 0);
        assertEq(readPrice, uint256(minPrice), "price round-trip");
        assertEq(readMinSupply, uint256(minSupply), "min supply round-trip");
        assertEq(readMaxSupply, uint256(maxSupply), "max supply round-trip");
    }

    //*********************************************************************//
    // --- configurePostingCriteriaFor: Validation Errors ----------------- //
    //*********************************************************************//

    function test_configureReverts_zeroMinSupply() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 0,
            minimumTotalSupply: 0, // Zero!
            maximumTotalSupply: 100,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        vm.expectRevert(CTPublisher.CTPublisher_ZeroTotalSupply.selector);
        publisher.configurePostingCriteriaFor(posts);
    }

    function test_configureReverts_minGreaterThanMax() public {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 0,
            minimumTotalSupply: 100, // Greater than max!
            maximumTotalSupply: 50,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        vm.expectRevert(
            abi.encodeWithSelector(CTPublisher.CTPublisher_MaxTotalSupplyLessThanMin.selector, 100, 50)
        );
        publisher.configurePostingCriteriaFor(posts);
    }

    //*********************************************************************//
    // --- configurePostingCriteriaFor: Permission Checks ----------------- //
    //*********************************************************************//

    function test_configureReverts_ifUnauthorized() public {
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

    //*********************************************************************//
    // --- configurePostingCriteriaFor: Overwrite Previous Config --------- //
    //*********************************************************************//

    function test_configureOverwritesPrevious() public {
        // First configure.
        CTAllowedPost[] memory posts1 = new CTAllowedPost[](1);
        posts1[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 100,
            minimumTotalSupply: 10,
            maximumTotalSupply: 50,
            allowedAddresses: new address[](0)
        });
        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts1);

        // Overwrite.
        CTAllowedPost[] memory posts2 = new CTAllowedPost[](1);
        posts2[0] = CTAllowedPost({
            hook: hookAddr,
            category: 1,
            minimumPrice: 999,
            minimumTotalSupply: 1,
            maximumTotalSupply: 9999,
            allowedAddresses: new address[](0)
        });
        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts2);

        (uint256 minPrice, uint256 minSupply, uint256 maxSupply,) = publisher.allowanceFor(hookAddr, 1);
        assertEq(minPrice, 999, "price should be overwritten");
        assertEq(minSupply, 1, "min supply should be overwritten");
        assertEq(maxSupply, 9999, "max supply should be overwritten");
    }

    //*********************************************************************//
    // --- allowanceFor: Unconfigured Category --------------------------- //
    //*********************************************************************//

    function test_allowanceFor_unconfiguredReturnsZero() public {
        (uint256 minPrice, uint256 minSupply, uint256 maxSupply, address[] memory allowed) =
            publisher.allowanceFor(hookAddr, 999);

        assertEq(minPrice, 0);
        assertEq(minSupply, 0);
        assertEq(maxSupply, 0);
        assertEq(allowed.length, 0);
    }

    //*********************************************************************//
    // --- tierIdForEncodedIPFSUriOf ------------------------------------- //
    //*********************************************************************//

    function test_tierIdForEncodedIPFSUriOf_returnsZeroByDefault() public {
        bytes32 uri = keccak256("test");
        assertEq(publisher.tierIdForEncodedIPFSUriOf(hookAddr, uri), 0);
    }
}
