// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JB721TierFlags} from "@bananapus/721-hook-v6/src/structs/JB721TierFlags.sol";

import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";

contract CodexNemesisUriDriftTest is Test {
    bytes32 internal constant URI_A = keccak256("uri-a");
    bytes32 internal constant URI_B = keccak256("uri-b");

    JBPermissions internal permissions;
    MockTerminal internal terminal;
    MockDirectory internal directory;
    MockStore internal store;
    MockHook internal hook;
    CTPublisher internal publisher;

    address internal hookOwner = makeAddr("hookOwner");
    address internal poster = makeAddr("poster");
    uint256 internal constant FEE_PROJECT_ID = 1;
    uint256 internal constant PROJECT_ID = 42;

    function setUp() public {
        permissions = new JBPermissions(address(0));
        terminal = new MockTerminal();
        directory = new MockDirectory(IJBTerminal(address(terminal)));
        store = new MockStore();
        hook = new MockHook(hookOwner, PROJECT_ID, store);
        publisher = new CTPublisher(IJBDirectory(address(directory)), IJBPermissions(address(permissions)), FEE_PROJECT_ID, address(0));

        vm.deal(poster, 10 ether);

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

    function test_uriMutationDesyncAllowsDuplicateContentPublication() public {
        _publish(URI_A);

        assertEq(publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A), 1, "publisher should index URI_A -> tier 1");
        assertEq(store.tierUri(1), URI_A, "store should record tier 1 as URI_A");

        vm.prank(hookOwner);
        hook.setMetadata("", "", "", "", address(this), 1, URI_B);

        assertEq(store.tierUri(1), URI_B, "owner metadata update should move tier 1 to URI_B");
        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_A),
            1,
            "publisher mapping remains stale at URI_A -> tier 1"
        );
        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_B), 0, "publisher has no entry for the new URI yet"
        );

        _publish(URI_B);

        assertEq(store.maxTierId(), 2, "publishing URI_B again should create a fresh tier");
        assertEq(store.tierUri(1), URI_B, "tier 1 still points at URI_B after mutation");
        assertEq(store.tierUri(2), URI_B, "tier 2 now also points at URI_B");
        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(address(hook), URI_B),
            2,
            "publisher now tracks URI_B as a second tier instead of rejecting the duplicate"
        );
    }

    function _publish(bytes32 uri) internal {
        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: uri,
            totalSupply: 10,
            price: 1 ether,
            category: 7,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.prank(poster);
        publisher.mintFrom{value: 1.05 ether}(IJB721TiersHook(address(hook)), posts, poster, poster, "", "");
    }
}

contract MockDirectory {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IJBTerminal internal immutable _terminal;

    constructor(IJBTerminal terminal) {
        _terminal = terminal;
    }

    function primaryTerminalOf(uint256, address) external view returns (IJBTerminal) {
        return _terminal;
    }
}

contract MockTerminal {
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

contract MockStore {
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
        _tiers[tierId] =
            TierData({uri: config.encodedIPFSUri, price: config.price, category: config.category, supply: config.initialSupply, removed: false});
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

contract MockHook {
    address internal _owner;
    uint256 public immutable PROJECT_ID;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    MockStore internal immutable _store;

    constructor(address owner_, uint256 projectId, MockStore store_) {
        _owner = owner_;
        PROJECT_ID = projectId;
        _store = store_;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function STORE() external view returns (IJB721TiersHookStore) {
        return IJB721TiersHookStore(address(_store));
    }

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
