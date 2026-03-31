// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBOwnable} from "@bananapus/ownable-v6/src/interfaces/IJBOwnable.sol";
import {IJB721Hook} from "@bananapus/721-hook-v6/src/interfaces/IJB721Hook.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

/// @title L52_StaleTierIdMapping
/// @notice Stale tierIdForEncodedIPFSUriOf mapping after external tier removal.
///         When a tier is removed externally via adjustTiers(), the publisher's mapping still pointed
///         to the removed tier ID, blocking re-creation. The fix clears the stale mapping and allows
///         the post to fall through to new-tier creation.
contract L52_StaleTierIdMapping is Test {
    CTPublisher publisher;

    IJBPermissions permissions = IJBPermissions(makeAddr("permissions"));
    IJBDirectory directory = IJBDirectory(makeAddr("directory"));

    address hookOwner = makeAddr("hookOwner");
    address hookAddr = makeAddr("hook");
    address hookStoreAddr = makeAddr("hookStore");
    address terminalAddr = makeAddr("terminal");
    address poster = makeAddr("poster");

    uint256 feeProjectId = 1;
    uint256 hookProjectId = 42;

    bytes32 constant TEST_URI = keccak256("removable-content");

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
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(posts);
    }

    function _setupMintMocks(uint256 maxTierId) internal {
        vm.mockCall(
            hookStoreAddr, abi.encodeWithSelector(IJB721TiersHookStore.maxTierIdOf.selector), abi.encode(maxTierId)
        );
        vm.mockCall(hookAddr, abi.encodeWithSelector(IJB721TiersHook.adjustTiers.selector), abi.encode());
        vm.mockCall(hookAddr, abi.encodeWithSelector(bytes4(keccak256("METADATA_ID_TARGET()"))), abi.encode(address(0)));
        vm.mockCall(
            address(directory),
            abi.encodeWithSelector(IJBDirectory.primaryTerminalOf.selector),
            abi.encode(terminalAddr)
        );
        vm.mockCall(terminalAddr, "", abi.encode(uint256(0)));
    }

    /// @notice After a tier is removed externally, the stale mapping should be cleared
    ///         so that the same encodedIPFSUri can be re-posted as a new tier.
    function test_staleMappingClearedWhenTierRemoved() public {
        _configureCategory();

        // First mint: create tier 1 for TEST_URI.
        _setupMintMocks(0);

        // Mock isTierRemoved to return false (tier exists).
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.isTierRemoved.selector, hookAddr, 1),
            abi.encode(false)
        );

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: TEST_URI,
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");

        // Verify tier ID 1 was stored in the mapping.
        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(hookAddr, TEST_URI), 1, "tier ID should be stored after first mint"
        );

        // Now simulate external tier removal: isTierRemoved returns true for tier 1.
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.isTierRemoved.selector, hookAddr, 1),
            abi.encode(true)
        );

        // Update maxTierId to 1 so new tier gets ID 2.
        _setupMintMocks(1);

        // Second mint with the same URI should succeed (creating a new tier),
        // because the fix detects the stale mapping and clears it.
        vm.prank(poster);
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");

        // Verify the mapping now points to the new tier ID (2).
        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(hookAddr, TEST_URI),
            2,
            "tier ID should be updated to new tier after re-post"
        );
    }

    /// @notice When a tier is NOT removed, the mapping should be used as-is (no re-creation).
    function test_existingTierNotRemovedUsesMapping() public {
        _configureCategory();

        // First mint: create tier 1 for TEST_URI.
        _setupMintMocks(0);

        // Mock isTierRemoved to return false (tier exists).
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.isTierRemoved.selector, hookAddr, 1),
            abi.encode(false)
        );

        // Mock tierOf for tier 1 so the existing-tier price lookup succeeds.
        JB721Tier memory tier = JB721Tier({
            id: 1,
            price: 0.1 ether,
            remainingSupply: 9,
            initialSupply: 10,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: TEST_URI,
            category: 5,
            discountPercent: 0,
            allowOwnerMint: false,
            transfersPausable: false,
            cannotBeRemoved: false,
            cannotIncreaseDiscountPercent: false,
            cantBuyWithCredits: false,
            splitPercent: 0,
            resolvedUri: ""
        });
        vm.mockCall(
            hookStoreAddr,
            abi.encodeWithSelector(IJB721TiersHookStore.tierOf.selector, hookAddr, 1, false),
            abi.encode(tier)
        );

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: TEST_URI,
            totalSupply: 10,
            price: 0.1 ether,
            category: 5,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");

        assertEq(publisher.tierIdForEncodedIPFSUriOf(hookAddr, TEST_URI), 1);

        // Second mint with existing tier (not removed) — should reuse tier ID 1.
        _setupMintMocks(1);

        vm.prank(poster);
        publisher.mintFrom{value: 0.2 ether}(IJB721TiersHook(hookAddr), posts, poster, poster, "", "");

        // Mapping should still point to tier 1.
        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(hookAddr, TEST_URI),
            1,
            "tier ID should remain unchanged when tier is not removed"
        );
    }
}
