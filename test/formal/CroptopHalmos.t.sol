// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBBeforeCashOutRecordedContext} from "@bananapus/core-v6/src/structs/JBBeforeCashOutRecordedContext.sol";
import {JBRuleset} from "@bananapus/core-v6/src/structs/JBRuleset.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {JBTokenAmount} from "@bananapus/core-v6/src/structs/JBTokenAmount.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";
import {ICTDeployer} from "../../src/interfaces/ICTDeployer.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

/// @notice Halmos proofs for Croptop publisher tier setup and deployer sucker-accounting branches.
contract CroptopHalmos {
    //*********************************************************************//
    // -------------------- internal stored properties ------------------- //
    //*********************************************************************//

    /// @notice Deployer under test for sucker cash-out and interface proofs.
    CTDeployer internal _deployer;

    /// @notice Mock 721 hook used by the publisher harness.
    Mock721Hook internal _hook;

    /// @notice Publisher harness exposing `_setupPosts`.
    CTPublisherHarness internal _publisher;

    /// @notice Mock sucker registry used by `CTDeployer`.
    MockSuckerRegistry internal _suckerRegistry;

    /// @notice Mock 721 store backing the hook.
    Mock721Store internal _store;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor() {
        MockPermissions permissions = new MockPermissions();

        _store = new Mock721Store();
        _hook = new Mock721Hook({store: _store, owner_: address(77), projectId_: 42});
        _publisher = new CTPublisherHarness({
            directory: address(1), permissions: permissions, feeProjectId: 1, trustedForwarder: address(0)
        });
        _suckerRegistry = new MockSuckerRegistry();

        _deployer = new CTDeployer({
            permissions: IJBPermissions(address(permissions)),
            projects: IJBProjects(address(2)),
            deployer: IJB721TiersHookDeployer(address(3)),
            publisher: _publisher,
            suckerRegistry: IJBSuckerRegistry(address(_suckerRegistry)),
            trustedForwarder: address(0)
        });
    }

    //*********************************************************************//
    // ----------------------- public transactions ----------------------- //
    //*********************************************************************//

    /// @notice Proves allowance bit packing round-trips through the public configuration surface.
    /// @param category The category whose allowance is configured.
    /// @param maximumSplitPercent The maximum split percent allowed for the category.
    /// @param maximumTotalSupply The maximum supply, or 0 for unlimited.
    /// @param minimumPrice The minimum price for a post in this category.
    /// @param minimumTotalSupply The required minimum supply.
    function check_allowancePackingRoundTrips(
        uint24 category,
        uint32 maximumSplitPercent,
        uint32 maximumTotalSupply,
        uint104 minimumPrice,
        uint32 minimumTotalSupply
    )
        public
    {
        if (minimumTotalSupply == 0) return;
        if (maximumTotalSupply != 0 && maximumTotalSupply < minimumTotalSupply) return;

        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: address(_hook),
            category: category,
            minimumPrice: minimumPrice,
            minimumTotalSupply: minimumTotalSupply,
            maximumTotalSupply: maximumTotalSupply,
            maximumSplitPercent: maximumSplitPercent,
            allowedAddresses: new address[](0)
        });

        _publisher.configurePostingCriteriaFor({allowedPosts: allowedPosts});

        (
            uint256 returnedMinimumPrice,
            uint256 returnedMinimumTotalSupply,
            uint256 returnedMaximumTotalSupply,
            uint256 returnedMaximumSplitPercent,
            address[] memory returnedAllowedAddresses
        ) = _publisher.allowanceFor({hook: address(_hook), category: category});

        assert(returnedMinimumPrice == minimumPrice);
        assert(returnedMinimumTotalSupply == minimumTotalSupply);
        assert(returnedMaximumTotalSupply == maximumTotalSupply);
        assert(returnedMaximumSplitPercent == maximumSplitPercent);
        assert(returnedAllowedAddresses.length == 0);
    }

    /// @notice Proves non-sucker cash outs pass through local values when no collection data hook is set.
    /// @param cashOutCount The cash-out count from the terminal context.
    /// @param cashOutTaxRate The cash-out tax rate from the terminal context.
    /// @param surplus The local surplus from the terminal context.
    /// @param totalSupply The local total supply from the terminal context.
    function check_beforeCashOutDefaultsWithoutHookForNonSucker(
        uint96 cashOutCount,
        uint16 cashOutTaxRate,
        uint96 surplus,
        uint96 totalSupply
    )
        public
        view
    {
        address holder = address(5);

        (
            uint256 returnedCashOutTaxRate,
            uint256 returnedCashOutCount,
            uint256 returnedTotalSupply,
            uint256 returnedSurplus,
        ) = _deployer.beforeCashOutRecordedWith(
            _cashOutContext({
                holder: holder,
                projectId: 1,
                cashOutCount: cashOutCount,
                totalSupply: totalSupply,
                surplus: surplus,
                cashOutTaxRate: cashOutTaxRate
            })
        );

        assert(returnedCashOutTaxRate == cashOutTaxRate);
        assert(returnedCashOutCount == cashOutCount);
        assert(returnedTotalSupply == totalSupply);
        assert(returnedSurplus == surplus);
    }

    /// @notice Proves sucker cash outs bypass tax and use only the local terminal accounting values.
    /// @param cashOutCount The local cash-out count.
    /// @param cashOutTaxRate The input tax rate that should be ignored for suckers.
    /// @param surplus The local surplus value.
    /// @param totalSupply The local total supply.
    function check_beforeCashOutUsesLocalStateForSucker(
        uint96 cashOutCount,
        uint16 cashOutTaxRate,
        uint96 surplus,
        uint96 totalSupply
    )
        public
    {
        uint256 projectId = 1;
        address sucker = address(5);

        _suckerRegistry.setSucker({projectId: projectId, sucker: sucker, flag: true});

        (
            uint256 returnedCashOutTaxRate,
            uint256 returnedCashOutCount,
            uint256 returnedTotalSupply,
            uint256 returnedSurplus,
        ) = _deployer.beforeCashOutRecordedWith(
            _cashOutContext({
                holder: sucker,
                projectId: projectId,
                cashOutCount: cashOutCount,
                totalSupply: totalSupply,
                surplus: surplus,
                cashOutTaxRate: cashOutTaxRate
            })
        );

        assert(returnedCashOutTaxRate == 0);
        assert(returnedCashOutCount == cashOutCount);
        assert(returnedTotalSupply == totalSupply);
        assert(returnedSurplus == surplus);
    }

    /// @notice Proves existing-tier reuse charges the canonical tier price instead of caller-provided post price.
    /// @param cachedPrice The price currently stored on the 721 tier.
    /// @param callerPrice The caller-provided price, which must not affect existing-tier payment accounting.
    function check_existingTierUsesCachedPrice(uint96 cachedPrice, uint96 callerPrice) public {
        bytes32 uri = bytes32(uint256(1));
        uint32 tierId = 7;

        _publisher.setTierIdForProof({hook: address(_hook), encodedIpfsUri: uri, tierId: tierId});
        _store.setTier({id: tierId, encodedIpfsUri: uri, price: uint104(cachedPrice), removed: false});

        (JB721TierConfig[] memory tiersToAdd, uint256[] memory tierIdsToMint, uint256 totalPrice) = _publisher.setupPostsForProof({
            hook: IJB721TiersHook(address(_hook)),
            posts: _post({uri: uri, category: 1, price: uint104(callerPrice), totalSupply: 1})
        });

        assert(tiersToAdd.length == 0);
        assert(tierIdsToMint.length == 1);
        assert(tierIdsToMint[0] == tierId);
        assert(totalPrice == cachedPrice);
    }

    /// @notice Proves mint permission is exactly the sucker-registry decision for the project/address pair.
    /// @param expected Whether the registry marks the address as a sucker.
    /// @param projectId The project ID under test.
    function check_hasMintPermissionMatchesRegistry(bool expected, uint96 projectId) public {
        address addr = address(5);
        JBRuleset memory ruleset;

        _suckerRegistry.setSucker({projectId: projectId, sucker: addr, flag: expected});

        assert(_deployer.hasMintPermissionFor(projectId, ruleset, addr) == expected);
    }

    /// @notice Proves duplicate IPFS URIs in one publish batch are rejected before a second tier can be added.
    function check_setupPostsRejectsDuplicateUri() public {
        bytes32 uri = bytes32(uint256(1));

        _configureCategory({category: 1});

        try _publisher.setupPostsForProof({
            hook: IJB721TiersHook(address(_hook)),
            posts: _posts({
                firstCategory: 1,
                firstPrice: 1,
                firstSupply: 1,
                firstUri: uri,
                secondCategory: 1,
                secondPrice: 1,
                secondSupply: 1,
                secondUri: uri
            })
        }) returns (
            JB721TierConfig[] memory, uint256[] memory, uint256
        ) {
            assert(false);
        } catch {}
    }

    /// @notice Proves empty IPFS URIs are rejected before tier creation.
    function check_setupPostsRejectsEmptyUri() public {
        _configureCategory({category: 1});

        try _publisher.setupPostsForProof({
            hook: IJB721TiersHook(address(_hook)),
            posts: _post({uri: bytes32(0), category: 1, price: 1, totalSupply: 1})
        }) returns (
            JB721TierConfig[] memory, uint256[] memory, uint256
        ) {
            assert(false);
        } catch {}
    }

    /// @notice Proves new tiers are sorted for the 721 store while mint IDs stay aligned to original post order.
    /// @param firstCategory The first post's category.
    /// @param firstPrice The first post's price.
    /// @param firstSupply The first post's supply.
    /// @param secondCategory The second post's category.
    /// @param secondPrice The second post's price.
    /// @param secondSupply The second post's supply.
    function check_setupPostsSortsNewTiersAndPreservesMintOrder(
        uint8 firstCategory,
        uint96 firstPrice,
        uint16 firstSupply,
        uint8 secondCategory,
        uint96 secondPrice,
        uint16 secondSupply
    )
        public
    {
        if (firstSupply == 0 || secondSupply == 0) return;

        bytes32 firstUri = bytes32(uint256(1));
        bytes32 secondUri = bytes32(uint256(2));
        uint256 firstTierId = 11;
        uint256 secondTierId = 12;

        _store.setMaxTierId({maxTierId: 10});
        _configureCategory({category: firstCategory});
        _configureCategory({category: secondCategory});

        (JB721TierConfig[] memory tiersToAdd, uint256[] memory tierIdsToMint, uint256 totalPrice) = _publisher.setupPostsForProof({
            hook: IJB721TiersHook(address(_hook)),
            posts: _posts({
                firstCategory: firstCategory,
                firstPrice: uint104(firstPrice),
                firstSupply: uint32(firstSupply),
                firstUri: firstUri,
                secondCategory: secondCategory,
                secondPrice: uint104(secondPrice),
                secondSupply: uint32(secondSupply),
                secondUri: secondUri
            })
        });

        assert(tiersToAdd.length == 2);
        assert(tierIdsToMint.length == 2);
        assert(tiersToAdd[0].category <= tiersToAdd[1].category);
        assert(totalPrice == uint256(firstPrice) + secondPrice);

        if (firstCategory <= secondCategory) {
            assert(tiersToAdd[0].encodedIpfsUri == firstUri);
            assert(tiersToAdd[1].encodedIpfsUri == secondUri);
            assert(tierIdsToMint[0] == firstTierId);
            assert(tierIdsToMint[1] == secondTierId);
        } else {
            assert(tiersToAdd[0].encodedIpfsUri == secondUri);
            assert(tiersToAdd[1].encodedIpfsUri == firstUri);
            assert(tierIdsToMint[0] == secondTierId);
            assert(tierIdsToMint[1] == firstTierId);
        }

        assert(_publisher.tierIdForEncodedIpfsUriOf(address(_hook), firstUri) == tierIdsToMint[0]);
        assert(_publisher.tierIdForEncodedIpfsUriOf(address(_hook), secondUri) == tierIdsToMint[1]);
    }

    /// @notice Proves Croptop deployer reports the interfaces its callers depend on.
    function check_supportsExpectedInterfaces() public view {
        assert(_deployer.supportsInterface(type(ICTDeployer).interfaceId));
        assert(_deployer.supportsInterface(type(IERC721Receiver).interfaceId));
        assert(!_deployer.supportsInterface(bytes4(0)));
        assert(!_deployer.supportsInterface(bytes4(0xdeadbeef)));
    }

    //*********************************************************************//
    // ----------------------- internal helpers -------------------------- //
    //*********************************************************************//

    /// @notice Builds a cash-out context with only the fields read by `CTDeployer`.
    /// @param cashOutCount The cash-out count to include.
    /// @param cashOutTaxRate The cash-out tax rate to include.
    /// @param holder The token holder cashing out.
    /// @param projectId The project ID to include.
    /// @param surplus The local surplus value to include.
    /// @param totalSupply The local total supply to include.
    function _cashOutContext(
        address holder,
        uint256 projectId,
        uint256 cashOutCount,
        uint256 totalSupply,
        uint256 surplus,
        uint256 cashOutTaxRate
    )
        internal
        pure
        returns (JBBeforeCashOutRecordedContext memory context)
    {
        context.holder = holder;
        context.projectId = projectId;
        context.cashOutCount = cashOutCount;
        context.totalSupply = totalSupply;
        context.surplus = JBTokenAmount({token: address(0), decimals: 18, currency: 1, value: surplus});
        context.cashOutTaxRate = cashOutTaxRate;
    }

    /// @notice Installs a permissive category allowance for new-tier creation proofs.
    /// @param category The category to configure.
    function _configureCategory(uint24 category) internal {
        _publisher.setAllowanceForProof({
            hook: address(_hook),
            category: category,
            minimumPrice: 0,
            minimumTotalSupply: 1,
            maximumTotalSupply: 0,
            maximumSplitPercent: type(uint32).max
        });
    }

    /// @notice Builds a single-post array for publisher setup proofs.
    /// @param category The post category.
    /// @param price The post price.
    /// @param totalSupply The post supply.
    /// @param uri The post URI.
    function _post(
        bytes32 uri,
        uint24 category,
        uint104 price,
        uint32 totalSupply
    )
        internal
        pure
        returns (CTPost[] memory posts)
    {
        posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIpfsUri: uri,
            totalSupply: totalSupply,
            price: price,
            category: category,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
    }

    /// @notice Builds a two-post array for publisher setup proofs.
    /// @param firstCategory The first post category.
    /// @param firstPrice The first post price.
    /// @param firstSupply The first post supply.
    /// @param firstUri The first post URI.
    /// @param secondCategory The second post category.
    /// @param secondPrice The second post price.
    /// @param secondSupply The second post supply.
    /// @param secondUri The second post URI.
    function _posts(
        uint24 firstCategory,
        uint104 firstPrice,
        uint32 firstSupply,
        bytes32 firstUri,
        uint24 secondCategory,
        uint104 secondPrice,
        uint32 secondSupply,
        bytes32 secondUri
    )
        internal
        pure
        returns (CTPost[] memory posts)
    {
        posts = new CTPost[](2);
        posts[0] = CTPost({
            encodedIpfsUri: firstUri,
            totalSupply: firstSupply,
            price: firstPrice,
            category: firstCategory,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
        posts[1] = CTPost({
            encodedIpfsUri: secondUri,
            totalSupply: secondSupply,
            price: secondPrice,
            category: secondCategory,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });
    }
}

/// @notice Harness that exposes CTPublisher's internal post setup logic to Halmos.
contract CTPublisherHarness is CTPublisher {
    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param directory The mocked directory address.
    /// @param feeProjectId The fee project ID.
    /// @param permissions The mocked permissions contract.
    /// @param trustedForwarder The ERC2771 trusted forwarder.
    constructor(
        address directory,
        MockPermissions permissions,
        uint256 feeProjectId,
        address trustedForwarder
    )
        CTPublisher(IJBDirectory(directory), IJBPermissions(address(permissions)), feeProjectId, trustedForwarder)
    {}

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Writes a packed allowance directly so proofs can focus on post setup.
    /// @param category The category to configure.
    /// @param hook The hook whose category is configured.
    /// @param maximumSplitPercent The max split percent.
    /// @param maximumTotalSupply The max supply, or 0 for unlimited.
    /// @param minimumPrice The minimum post price.
    /// @param minimumTotalSupply The minimum post supply.
    function setAllowanceForProof(
        address hook,
        uint24 category,
        uint104 minimumPrice,
        uint32 minimumTotalSupply,
        uint32 maximumTotalSupply,
        uint32 maximumSplitPercent
    )
        external
    {
        uint256 packed;
        packed |= uint256(minimumPrice);
        packed |= uint256(minimumTotalSupply) << 104;
        packed |= uint256(maximumTotalSupply) << 136;
        packed |= uint256(maximumSplitPercent) << 168;
        _packedAllowanceFor[hook][category] = packed;
    }

    /// @notice Seeds an existing URI-to-tier mapping.
    /// @param encodedIpfsUri The URI key.
    /// @param hook The hook whose mapping is seeded.
    /// @param tierId The existing tier ID.
    function setTierIdForProof(address hook, bytes32 encodedIpfsUri, uint256 tierId) external {
        tierIdForEncodedIpfsUriOf[hook][encodedIpfsUri] = tierId;
    }

    /// @notice External wrapper around `_setupPosts`.
    /// @param hook The 721 hook under test.
    /// @param posts The posts to set up.
    /// @return tiersToAdd The tiers to create.
    /// @return tierIdsToMint The tier IDs to mint, aligned with `posts`.
    /// @return totalPrice The total price used by fee/payment accounting.
    function setupPostsForProof(
        IJB721TiersHook hook,
        CTPost[] memory posts
    )
        external
        returns (JB721TierConfig[] memory tiersToAdd, uint256[] memory tierIdsToMint, uint256 totalPrice)
    {
        return _setupPosts({hook: hook, posts: posts});
    }
}

/// @notice Minimal 721 hook mock exposing only methods used by CTPublisher proofs.
contract Mock721Hook {
    //*********************************************************************//
    // ---------------- public immutable stored properties --------------- //
    //*********************************************************************//

    /// @notice The store returned by `STORE()`.
    Mock721Store public immutable STORE;

    /// @notice The collection owner returned by `owner()`.
    address public immutable owner;

    /// @notice The project ID returned by `projectId()`.
    uint256 public immutable projectId;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    /// @param owner_ The mocked collection owner.
    /// @param projectId_ The mocked project ID.
    /// @param store The mocked 721 store.
    constructor(Mock721Store store, address owner_, uint256 projectId_) {
        STORE = store;
        owner = owner_;
        projectId = projectId_;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Stubbed metadata target, unused by `_setupPosts`.
    function METADATA_ID_TARGET() external pure returns (address) {
        return address(0);
    }
}

/// @notice Minimal 721 store mock for publisher tier lookup proofs.
contract Mock721Store {
    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice Mock max tier ID.
    uint256 internal _maxTierId;

    /// @notice Mock removal status by tier ID.
    mapping(uint256 tierId => bool) internal _removed;

    /// @notice Mock tier data by tier ID.
    mapping(uint256 tierId => JB721Tier) internal _tierOf;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Sets the max tier ID returned by `maxTierIdOf`.
    /// @param maxTierId The max tier ID.
    function setMaxTierId(uint256 maxTierId) external {
        _maxTierId = maxTierId;
    }

    /// @notice Sets a tier's mocked data and removal status.
    /// @param encodedIpfsUri The tier URI.
    /// @param id The tier ID.
    /// @param price The tier price.
    /// @param removed Whether the tier is removed.
    function setTier(uint32 id, bytes32 encodedIpfsUri, uint104 price, bool removed) external {
        _tierOf[id].id = id;
        _tierOf[id].encodedIpfsUri = encodedIpfsUri;
        _tierOf[id].price = price;
        _removed[id] = removed;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Whether the mocked tier was removed.
    /// @param tierId The tier ID.
    function isTierRemoved(address, uint256 tierId) external view returns (bool) {
        return _removed[tierId];
    }

    /// @notice The mocked max tier ID.
    function maxTierIdOf(address) external view returns (uint256) {
        return _maxTierId;
    }

    /// @notice The mocked tier data.
    /// @param id The tier ID.
    function tierOf(address, uint256 id, bool) external view returns (JB721Tier memory tier) {
        return _tierOf[id];
    }
}

/// @notice Minimal permissions mock used by publisher/deployer constructors.
contract MockPermissions {
    /// @notice Always grants the requested permission.
    function hasPermission(address, address, uint256, uint256, bool, bool) external pure returns (bool) {
        return true;
    }

    /// @notice Accepts permission writes performed by constructors.
    function setPermissionsFor(address, JBPermissionsData calldata) external pure {}
}

/// @notice Minimal sucker registry mock used by CTDeployer proofs.
contract MockSuckerRegistry {
    //*********************************************************************//
    // --------------------- internal stored properties ------------------ //
    //*********************************************************************//

    /// @notice Mock sucker membership by project and address.
    mapping(uint256 projectId => mapping(address sucker => bool)) internal _isSuckerOf;

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Sets mocked sucker membership.
    /// @param flag Whether the address is a sucker.
    /// @param projectId The project ID.
    /// @param sucker The address to configure.
    function setSucker(uint256 projectId, address sucker, bool flag) external {
        _isSuckerOf[projectId][sucker] = flag;
    }

    //*********************************************************************//
    // ------------------------- external views -------------------------- //
    //*********************************************************************//

    /// @notice Returns mocked sucker membership.
    /// @param addr The address to check.
    /// @param projectId The project ID.
    function isSuckerOf(uint256 projectId, address addr) external view returns (bool) {
        return _isSuckerOf[projectId][addr];
    }
}
