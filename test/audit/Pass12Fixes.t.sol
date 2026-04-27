// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

// ---------------------------------------------------------------------------
// Minimal mock contracts (reusable across both tests)
// ---------------------------------------------------------------------------

contract P12MockTerminal {
    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        return 0;
    }
}

contract P12MockDirectory {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IJBTerminal internal immutable _terminal;

    constructor(IJBTerminal terminal_) {
        _terminal = terminal_;
    }

    function primaryTerminalOf(uint256, address) external view returns (IJBTerminal) {
        return _terminal;
    }
}

contract P12MockStore {
    struct TierData {
        bytes32 uri;
        uint104 price;
        uint24 category;
        uint32 supply;
        bool removed;
    }

    uint256 internal _maxTierId;
    mapping(uint256 tierId => TierData) internal _tiers;

    function maxTierIdOf(address) external view returns (uint256) {
        return _maxTierId;
    }

    function isTierRemoved(address, uint256 tierId) external view returns (bool) {
        return _tiers[tierId].removed;
    }

    function tierOf(address, uint256 tierId, bool) external view returns (JB721Tier memory) {
        TierData memory tier = _tiers[tierId];
        return JB721Tier({
            // forge-lint: disable-next-line(unsafe-typecast)
            id: uint32(tierId),
            price: tier.price,
            remainingSupply: tier.supply,
            initialSupply: tier.supply,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: tier.uri,
            category: tier.category,
            discountPercent: 0,
            flags: JB721TierFlags({
                allowOwnerMint: false,
                transfersPausable: false,
                cantBeRemoved: false,
                cantIncreaseDiscountPercent: false,
                cantBuyWithCredits: false
            }),
            splitPercent: 0,
            resolvedUri: ""
        });
    }

    function addTier(JB721TierConfig calldata config) external returns (uint256 tierId) {
        tierId = ++_maxTierId;
        _tiers[tierId] = TierData({
            uri: config.encodedIPFSUri,
            price: config.price,
            category: config.category,
            supply: config.initialSupply,
            removed: false
        });
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function setEncodedIPFSUriOf(uint256 tierId, bytes32 uri) external {
        _tiers[tierId].uri = uri;
    }

    function tierUri(uint256 tierId) external view returns (bytes32) {
        return _tiers[tierId].uri;
    }

    function maxTierId() external view returns (uint256) {
        return _maxTierId;
    }
}

contract P12MockHook {
    address internal _owner;
    uint256 public immutable PROJECT_ID;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    P12MockStore internal immutable _store;

    constructor(address owner_, uint256 projectId_, P12MockStore store_) {
        _owner = owner_;
        PROJECT_ID = projectId_;
        _store = store_;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function STORE() external view returns (IJB721TiersHookStore) {
        return IJB721TiersHookStore(address(_store));
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function METADATA_ID_TARGET() external view returns (address) {
        return address(this);
    }

    function adjustTiers(JB721TierConfig[] calldata tiersToAdd, uint256[] calldata) external {
        for (uint256 i; i < tiersToAdd.length; i++) {
            _store.addTier(tiersToAdd[i]);
        }
    }

    function setMetadata(
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        address,
        uint256 encodedIPFSUriTierId,
        bytes32 encodedIPFSUri
    )
        external
    {
        require(msg.sender == _owner, "not owner");
        _store.setEncodedIPFSUriOf(encodedIPFSUriTierId, encodedIPFSUri);
    }
}

// ---------------------------------------------------------------------------
// Test contract
// ---------------------------------------------------------------------------

/// @notice Regression tests for Pass 12 audit fixes:
///   H-26: Metadata shadow — additionalPayMetadata with duplicate pay ID
///   M-42: URI cache desync — tier URI changed via setMetadata
contract Pass12FixesTest is Test {
    bytes32 internal constant URI_A = keccak256("uri-a");
    bytes32 internal constant URI_B = keccak256("uri-b");

    JBPermissions internal permissions;
    P12MockTerminal internal terminal;
    P12MockDirectory internal directory;
    P12MockStore internal store;
    P12MockHook internal hook;
    CTPublisher internal publisher;

    address internal hookOwner = makeAddr("hookOwner");
    address internal poster = makeAddr("poster");
    uint256 internal constant FEE_PROJECT_ID = 1;
    uint256 internal constant PROJECT_ID = 42;

    function setUp() public {
        permissions = new JBPermissions(address(0));
        terminal = new P12MockTerminal();
        directory = new P12MockDirectory(IJBTerminal(address(terminal)));
        store = new P12MockStore();
        hook = new P12MockHook(hookOwner, PROJECT_ID, store);
        publisher = new CTPublisher(
            IJBDirectory(address(directory)), IJBPermissions(address(permissions)), FEE_PROJECT_ID, address(0)
        );

        vm.deal(poster, 100 ether);

        // Configure a category that allows posting.
        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: address(hook),
            category: 7,
            minimumPrice: 1 ether,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(allowedPosts);
    }

    // -----------------------------------------------------------------------
    // H-26: Metadata shadow — duplicate pay ID in additionalPayMetadata
    // -----------------------------------------------------------------------

    /// @notice When additionalPayMetadata already contains an entry for the pay ID,
    ///         the fix should revert with CTPublisher_DuplicatePayMetadata.
    function test_H26_fix_reverts_duplicate_metadata() public {
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: URI_A,
            totalSupply: 10,
            price: 1 ether,
            category: 7,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Build metadata that already contains the pay ID for this hook.
        address metadataIdTarget = address(hook); // hook.METADATA_ID_TARGET() returns address(hook)
        uint16[] memory forgedTierIds = new uint16[](1);
        forgedTierIds[0] = 999; // Attacker's desired tier
        bytes4[] memory ids = new bytes4[](1);
        bytes[] memory datas = new bytes[](1);
        ids[0] = JBMetadataResolver.getId({purpose: "pay", target: metadataIdTarget});
        datas[0] = abi.encode(true, forgedTierIds);
        bytes memory shadowingMetadata = JBMetadataResolver.createMetadata(ids, datas);

        vm.prank(poster);
        vm.expectRevert(CTPublisher.CTPublisher_DuplicatePayMetadata.selector);
        publisher.mintFrom{value: 1.05 ether}(
            IJB721TiersHook(address(hook)), posts, poster, poster, shadowingMetadata, ""
        );
    }

    /// @notice Empty additionalPayMetadata should NOT revert.
    function test_H26_fix_allows_empty_metadata() public {
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: URI_A,
            totalSupply: 10,
            price: 1 ether,
            category: 7,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Empty metadata — should succeed.
        vm.prank(poster);
        publisher.mintFrom{value: 1.05 ether}(IJB721TiersHook(address(hook)), posts, poster, poster, "", "");

        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 1, "tier should be created with empty metadata"
        );
    }

    /// @notice additionalPayMetadata with a DIFFERENT ID (not the pay ID) should NOT revert.
    function test_H26_fix_allows_unrelated_metadata() public {
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: URI_A,
            totalSupply: 10,
            price: 1 ether,
            category: 7,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        // Build metadata with a different purpose — should NOT trigger the check.
        bytes4[] memory ids = new bytes4[](1);
        bytes[] memory datas = new bytes[](1);
        ids[0] = JBMetadataResolver.getId({purpose: "unrelated", target: address(hook)});
        datas[0] = abi.encode(uint256(42));
        bytes memory unrelatedMetadata = JBMetadataResolver.createMetadata(ids, datas);

        vm.prank(poster);
        publisher.mintFrom{value: 1.05 ether}(
            IJB721TiersHook(address(hook)), posts, poster, poster, unrelatedMetadata, ""
        );

        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A),
            1,
            "tier should be created with unrelated metadata"
        );
    }

    // -----------------------------------------------------------------------
    // M-42: URI cache desync — tier URI changed via setMetadata
    // -----------------------------------------------------------------------

    /// @notice When a tier's URI is changed via setMetadata, the cache entry
    ///         (old URI -> tier ID) becomes stale. The fix should detect
    ///         the mismatch and clear the cache, creating a new tier.
    function test_M42_fix_clears_stale_cache() public {
        // Step 1: Publish URI_A — creates tier 1.
        _publish(URI_A);
        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 1, "URI_A cached as tier 1");

        // Step 2: Owner changes tier 1's URI from URI_A to URI_B via setMetadata.
        vm.prank(hookOwner);
        hook.setMetadata("", "", "", "", address(this), 1, URI_B);

        // The publisher cache still maps URI_A -> tier 1, but tier 1 now has URI_B.
        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 1, "stale cache still maps URI_A -> tier 1");

        // Step 3: Try to publish URI_A again. The fix should detect the mismatch
        // (tier 1's actual URI is URI_B, not URI_A), clear the stale cache, and
        // create a new tier 2 for URI_A.
        _publish(URI_A);

        assertEq(store.maxTierId(), 2, "new tier should be created for URI_A after cache invalidation");
        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 2, "URI_A should now map to tier 2 (fresh tier)"
        );
    }

    /// @notice When the tier was removed, the cache should still be cleared (existing behavior preserved).
    function test_M42_fix_still_handles_removed_tiers() public {
        // Use vm.mockCall to simulate isTierRemoved returning true for tier 1.
        _publish(URI_A);
        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 1, "URI_A cached as tier 1");

        // Mock isTierRemoved to return true for tier 1.
        vm.mockCall(
            address(store),
            abi.encodeWithSelector(IJB721TiersHookStore.isTierRemoved.selector, address(hook), uint256(1)),
            abi.encode(true)
        );

        // Publish URI_A again — should clear stale mapping and create tier 2.
        _publish(URI_A);

        assertEq(store.maxTierId(), 2, "new tier should be created after tier removal");
        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 2, "URI_A should map to new tier 2");
    }

    /// @notice When a cached tier's URI still matches, it should be reused (no regression).
    function test_M42_fix_reuses_valid_cache() public {
        // Publish URI_A — creates tier 1.
        _publish(URI_A);
        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 1, "URI_A cached as tier 1");

        // Publish URI_A again — URI still matches, should reuse tier 1 (no new tier created).
        _publish(URI_A);
        assertEq(store.maxTierId(), 1, "no new tier should be created for matching URI");
        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 1, "URI_A still maps to tier 1");
    }

    // -----------------------------------------------------------------------
    // Helper
    // -----------------------------------------------------------------------

    function _publish(bytes32 uri) internal {
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: uri, totalSupply: 10, price: 1 ether, category: 7, splitPercent: 0, splits: new JBSplit[](0)
        });

        vm.prank(poster);
        publisher.mintFrom{value: 1.05 ether}(IJB721TiersHook(address(hook)), posts, poster, poster, "", "");
    }
}
