// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJB721Hook} from "@bananapus/721-hook-v6/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

/// @title M6_DuplicateUriFeeEvasion
/// @notice Duplicate encodedIPFSUri in a single mintFrom batch
///         enables fee evasion. Before the fix, a second post with the same URI would read
///         a stale tierIdForEncodedIPFSUriOf mapping (written by _setupPosts for the first
///         post but not yet committed to the store), causing store.tierOf() to return price=0,
///         so the fee was computed on 1x the price instead of 2x.
///         The fix reverts with CTPublisher_DuplicatePost when duplicate URIs appear in a batch.
contract M6_DuplicateUriFeeEvasion is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr = makeAddr("hookStore");
    address terminalAddr = makeAddr("terminal");
    address feeTerminalAddr = makeAddr("feeTerminal");
    address poster = makeAddr("poster");

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
            address(permissions), abi.encodeWithSelector(IJBPermissions.hasPermission.selector), abi.encode(true)
        );

        // Fund poster.
        vm.deal(poster, 100 ether);
    }

    function _configureCategory() internal {
        CTAllowedPost[] memory posts = new CTAllowedPost[](1);
        posts[0] = CTAllowedPost({
            hook: hookAddr,
            category: 5,
            minimumPrice: 0.01 ether,
            minimumTotalSupply: 1,
            maximumTotalSupply: 1000,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);
    }

    function _setupMintMocks() internal {
        vm.mockCall(
            hookStoreAddr, abi.encodeWithSelector(IJB721TiersHookStore.maxTierIdOf.selector), abi.encode(uint256(0))
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        vm.mockCall(hookAddr, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, hookProjectId),
            abi.encode(terminalAddr)
        );
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector, feeProjectId),
            abi.encode(feeTerminalAddr)
        );
        vm.mockCall(terminalAddr, "", abi.encode(uint256(0)));
        vm.mockCall(feeTerminalAddr, "", abi.encode(uint256(0)));
    }

    // =========================================================================
    // Test 1: Duplicate URI in batch reverts with CTPublisher_DuplicatePost
    // =========================================================================
    /// @notice Sending two posts with the same encodedIPFSUri in a single mintFrom batch
    ///         must revert with CTPublisher_DuplicatePost.
    function test_duplicateUriInBatch_reverts() public {
        _configureCategory();
        _setupMintMocks();

        bytes32 duplicateUri = keccak256("same-content");

        CTPost[] memory posts = new CTPost[](2);
        posts[0] = CTPost({
            encodedIPFSUri: duplicateUri,
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
        posts[1] = CTPost({
            encodedIPFSUri: duplicateUri, // Same URI as posts[0].
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_DuplicatePost.selector, duplicateUri));
        publisher.mintFrom{value: 1 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 2: Three posts, first and third duplicate — reverts
    // =========================================================================
    /// @notice Duplicates do not need to be adjacent to be caught.
    function test_duplicateUriNonAdjacent_reverts() public {
        _configureCategory();
        _setupMintMocks();

        bytes32 duplicateUri = keccak256("content-A");
        bytes32 uniqueUri = keccak256("content-B");

        CTPost[] memory posts = new CTPost[](3);
        posts[0] = CTPost({
            encodedIPFSUri: duplicateUri,
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
        posts[1] = CTPost({
            encodedIPFSUri: uniqueUri, // Different URI.
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
        posts[2] = CTPost({
            encodedIPFSUri: duplicateUri, // Same as posts[0].
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_DuplicatePost.selector, duplicateUri));
        publisher.mintFrom{value: 1 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
    }

    // =========================================================================
    // Test 3: Two posts with different URIs succeed
    // =========================================================================
    /// @notice Two posts with distinct encodedIPFSUri values should not revert
    ///         (at least not with the duplicate error).
    function test_distinctUrisInBatch_succeeds() public {
        _configureCategory();
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](2);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("content-1"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
        posts[1] = CTPost({
            encodedIPFSUri: keccak256("content-2"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Should not revert with CTPublisher_DuplicatePost.
        // May succeed fully or revert downstream in mocks, but never with the duplicate error.
        vm.prank(poster);
        try publisher.mintFrom{value: 1 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "") {}
        catch (bytes memory reason) {
            // Ensure it did NOT revert with CTPublisher_DuplicatePost.
            assertTrue(
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(CTPublisher.CTPublisher_DuplicatePost.selector, keccak256("content-1"))
                    ),
                "should not revert with duplicate post error for content-1"
            );
            assertTrue(
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(CTPublisher.CTPublisher_DuplicatePost.selector, keccak256("content-2"))
                    ),
                "should not revert with duplicate post error for content-2"
            );
        }
    }

    // =========================================================================
    // Test 4: Single post (no duplicates possible) succeeds
    // =========================================================================
    /// @notice A single post should never trigger the duplicate check.
    function test_singlePost_noDuplicateError() public {
        _configureCategory();
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("sole-content"),
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        try publisher.mintFrom{value: 1 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "") {}
        catch (bytes memory reason) {
            assertTrue(
                keccak256(reason)
                    != keccak256(
                        abi.encodeWithSelector(
                            CTPublisher.CTPublisher_DuplicatePost.selector, keccak256("sole-content")
                        )
                    ),
                "should not revert with duplicate post error"
            );
        }
    }

    // =========================================================================
    // Test 5: Fuzz — batch of 2 posts, duplicate iff URIs match
    // =========================================================================
    /// @notice Fuzz test: when two URIs are equal the call must revert with
    ///         CTPublisher_DuplicatePost; when they differ it must not.
    function testFuzz_duplicateDetection(bytes32 uri1, bytes32 uri2) public {
        // forge-lint: disable-next-line(unsafe-typecast)
        vm.assume(uri1 != bytes32(""));
        // forge-lint: disable-next-line(unsafe-typecast)
        vm.assume(uri2 != bytes32(""));

        _configureCategory();
        _setupMintMocks();

        CTPost[] memory posts = new CTPost[](2);
        posts[0] = CTPost({
            encodedIPFSUri: uri1,
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
        posts[1] = CTPost({
            encodedIPFSUri: uri2,
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        if (uri1 == uri2) {
            // Must revert with duplicate error.
            vm.prank(poster);
            vm.expectRevert(abi.encodeWithSelector(CTPublisher.CTPublisher_DuplicatePost.selector, uri1));
            publisher.mintFrom{value: 1 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");
        } else {
            // Must NOT revert with duplicate error. May still revert for other reasons
            // (e.g. mocked terminal behavior), but not CTPublisher_DuplicatePost.
            vm.prank(poster);
            try publisher.mintFrom{value: 1 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "") {}
            catch (bytes memory reason) {
                assertTrue(
                    keccak256(reason)
                        != keccak256(abi.encodeWithSelector(CTPublisher.CTPublisher_DuplicatePost.selector, uri1)),
                    "should not revert with duplicate post error for uri1"
                );
                assertTrue(
                    keccak256(reason)
                        != keccak256(abi.encodeWithSelector(CTPublisher.CTPublisher_DuplicatePost.selector, uri2)),
                    "should not revert with duplicate post error for uri2"
                );
            }
        }
    }
}
