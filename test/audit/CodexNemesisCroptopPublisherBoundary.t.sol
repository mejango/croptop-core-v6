// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";

contract NemesisMockPermissions is IJBPermissions {
    function WILDCARD_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function hasPermission(address, address, uint256, uint256, bool, bool) external pure returns (bool) {
        return true;
    }

    function hasPermissions(address, address, uint256, uint256[] calldata, bool, bool) external pure returns (bool) {
        return true;
    }

    function permissionsOf(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function setPermissionsFor(address, JBPermissionsData calldata) external {}
}

contract NemesisMockTerminal {
    mapping(uint256 projectId => uint256 amount) public paidToProject;

    function pay(
        uint256 projectId,
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
        paidToProject[projectId] += msg.value;
        return 0;
    }
}

contract NemesisMockDirectory {
    mapping(uint256 projectId => address terminal) public terminalOf;

    function setTerminal(uint256 projectId, address terminal) external {
        terminalOf[projectId] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address) external view returns (IJBTerminal) {
        return IJBTerminal(terminalOf[projectId]);
    }
}

contract NemesisMockStore {
    struct StoredTier {
        uint104 price;
        uint32 initialSupply;
        uint32 remainingSupply;
        bytes32 encodedIPFSUri;
        bool removed;
    }

    uint256 public maxTierId;
    mapping(uint256 tierId => StoredTier) public tierData;

    function encodedUriOf(uint256 tierId) external view returns (bytes32) {
        return tierData[tierId].encodedIPFSUri;
    }

    function addTier(JB721TierConfig memory config) external returns (uint256 tierId) {
        tierId = ++maxTierId;
        tierData[tierId] = StoredTier({
            price: config.price,
            initialSupply: config.initialSupply,
            remainingSupply: config.initialSupply,
            encodedIPFSUri: config.encodedIPFSUri,
            removed: false
        });
    }

    function setEncodedUri(uint256 tierId, bytes32 encodedIPFSUri) external {
        tierData[tierId].encodedIPFSUri = encodedIPFSUri;
    }

    function maxTierIdOf(address) external view returns (uint256) {
        return maxTierId;
    }

    function isTierRemoved(address, uint256 tierId) external view returns (bool) {
        return tierData[tierId].removed;
    }

    function tierOf(address, uint256 tierId, bool) external view returns (JB721Tier memory tier) {
        StoredTier memory stored = tierData[tierId];
        tier = JB721Tier({
            id: uint32(tierId),
            price: stored.price,
            remainingSupply: stored.remainingSupply,
            initialSupply: stored.initialSupply,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIPFSUri: stored.encodedIPFSUri,
            category: 0,
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
}

contract NemesisMutableHook {
    uint256 public immutable PROJECT_ID;
    IJB721TiersHookStore public immutable STORE;
    address public ownerAddress;

    constructor(uint256 projectId, IJB721TiersHookStore store_, address owner_) {
        PROJECT_ID = projectId;
        STORE = store_;
        ownerAddress = owner_;
    }

    function owner() external view returns (address) {
        return ownerAddress;
    }

    function METADATA_ID_TARGET() external view returns (address) {
        return address(this);
    }

    function adjustTiers(JB721TierConfig[] calldata tiersToAdd, uint256[] calldata) external {
        for (uint256 i; i < tiersToAdd.length; i++) {
            NemesisMockStore(address(STORE)).addTier(tiersToAdd[i]);
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
        NemesisMockStore(address(STORE)).setEncodedUri(encodedIPFSUriTierId, encodedIPFSUri);
    }
}

contract CodexNemesisCroptopPublisherBoundaryTest is Test {
    uint256 internal constant FEE_PROJECT_ID = 1;
    uint256 internal constant PROJECT_ID = 2;

    bytes32 internal constant URI_A = keccak256("uri-a");
    bytes32 internal constant URI_B = keccak256("uri-b");

    address internal hookOwner = makeAddr("hookOwner");
    address internal unrestrictedPoster = makeAddr("unrestrictedPoster");
    address internal restrictedPoster = makeAddr("restrictedPoster");
    address internal outsider = makeAddr("outsider");

    NemesisMockPermissions internal permissions;
    NemesisMockDirectory internal directory;
    NemesisMockStore internal store;
    NemesisMutableHook internal hook;
    NemesisMockTerminal internal projectTerminal;
    NemesisMockTerminal internal feeTerminal;
    CTPublisher internal publisher;

    function setUp() public {
        permissions = new NemesisMockPermissions();
        directory = new NemesisMockDirectory();
        store = new NemesisMockStore();
        hook = new NemesisMutableHook(PROJECT_ID, IJB721TiersHookStore(address(store)), hookOwner);
        projectTerminal = new NemesisMockTerminal();
        feeTerminal = new NemesisMockTerminal();
        publisher = new CTPublisher(IJBDirectory(address(directory)), permissions, FEE_PROJECT_ID, address(0));

        directory.setTerminal(PROJECT_ID, address(projectTerminal));
        directory.setTerminal(FEE_PROJECT_ID, address(feeTerminal));

        vm.deal(unrestrictedPoster, 100 ether);
        vm.deal(restrictedPoster, 100 ether);
        vm.deal(outsider, 100 ether);
    }

    function test_existingTierReuseBypassesUpdatedAllowlistAndPriceFloor() external {
        _configureCategory(1, 1 ether, _singletonArray(unrestrictedPoster));

        vm.prank(unrestrictedPoster);
        publisher.mintFrom{value: 2 ether}(
            IJB721TiersHook(address(hook)),
            _singlePost({uri: URI_A, price: 1 ether, category: 1}),
            unrestrictedPoster,
            unrestrictedPoster,
            "",
            ""
        );

        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 1, "initial publish should cache tier 1");

        // Tighten the policy so only `restrictedPoster` can publish, and only at >= 5 ether.
        _configureCategory(1, 5 ether, _singletonArray(restrictedPoster));

        vm.prank(outsider);
        publisher.mintFrom{value: 2 ether}(
            IJB721TiersHook(address(hook)),
            _singlePost({uri: URI_A, price: 0, category: 1}),
            outsider,
            outsider,
            "",
            ""
        );

        // The outsider's second call succeeds because existing-tier reuse skips the allowlist and price checks.
        assertEq(store.maxTierId(), 1, "reuse path should mint from the old tier instead of creating a new one");
        assertEq(
            projectTerminal.paidToProject(PROJECT_ID),
            3.9 ether,
            "both mints should settle against the stale reused tier price"
        );
        assertEq(
            feeTerminal.paidToProject(FEE_PROJECT_ID),
            0.1 ether,
            "fee routing still uses the stale reused tier price instead of the new stricter floor"
        );
    }

    function test_hookMetadataMutationDesyncsPublisherCacheAndAllowsDuplicateTier() external {
        _configureCategory(1, 1 ether, new address[](0));

        vm.prank(unrestrictedPoster);
        publisher.mintFrom{value: 2 ether}(
            IJB721TiersHook(address(hook)),
            _singlePost({uri: URI_A, price: 1 ether, category: 1}),
            unrestrictedPoster,
            unrestrictedPoster,
            "",
            ""
        );

        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 1, "publisher cache should point at tier 1");
        assertEq(store.encodedUriOf(1), URI_A, "canonical hook metadata should start at uri A");

        // The hook owner changes the canonical tier URI through the underlying 721 hook.
        vm.prank(hookOwner);
        hook.setMetadata("", "", "", "", address(0), 1, URI_B);

        assertEq(store.encodedUriOf(1), URI_B, "hook metadata now says tier 1 is uri B");
        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A),
            1,
            "publisher cache is stale and still thinks uri A owns tier 1"
        );

        vm.prank(unrestrictedPoster);
        publisher.mintFrom{value: 2 ether}(
            IJB721TiersHook(address(hook)),
            _singlePost({uri: URI_B, price: 1 ether, category: 1}),
            unrestrictedPoster,
            unrestrictedPoster,
            "",
            ""
        );

        // Croptop creates a second tier for the same canonical URI because it never re-syncs against hook metadata.
        assertEq(store.maxTierId(), 2, "publisher should have created a duplicate tier after the metadata drift");
        assertEq(store.encodedUriOf(1), URI_B, "tier 1 still resolves to uri B");
        assertEq(store.encodedUriOf(2), URI_B, "tier 2 now also resolves to uri B");
        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_B), 2, "cache now points uri B at tier 2");
    }

    function _configureCategory(uint24 category, uint104 minimumPrice, address[] memory allowedAddresses) internal {
        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: address(hook),
            category: category,
            minimumPrice: minimumPrice,
            minimumTotalSupply: 1,
            maximumTotalSupply: 100,
            maximumSplitPercent: 0,
            allowedAddresses: allowedAddresses
        });

        vm.prank(hookOwner);
        publisher.configurePostingCriteriaFor(allowedPosts);
    }

    function _singlePost(bytes32 uri, uint104 price, uint24 category) internal pure returns (CTPost[] memory posts) {
        posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: uri,
            totalSupply: 10,
            price: price,
            category: category,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
    }

    function _singletonArray(address account) internal pure returns (address[] memory addrs) {
        addrs = new address[](1);
        addrs[0] = account;
    }
}
