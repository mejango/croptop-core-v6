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
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
import {JBCurrencyIds} from "@bananapus/core-v6/src/libraries/JBCurrencyIds.sol";
import {JBAccountingContext} from "@bananapus/core-v6/src/structs/JBAccountingContext.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

contract PublishBoundaryPermissions is IJBPermissions {
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

    function setPermissionsFor(address, JBPermissionsData calldata) external pure {}
}

contract PublishBoundaryDirectory {
    mapping(uint256 projectId => IJBTerminal terminal) internal _terminalOf;

    function setTerminal(uint256 projectId, IJBTerminal terminal) external {
        _terminalOf[projectId] = terminal;
    }

    function primaryTerminalOf(uint256 projectId, address) external view returns (IJBTerminal) {
        return _terminalOf[projectId];
    }
}

contract PublishBoundaryTerminal {
    uint256 public paidValue;
    uint256 public paidProjectId;
    address public paidBeneficiary;

    function accountingContextForTokenOf(uint256, address token) external pure returns (JBAccountingContext memory) {
        return JBAccountingContext({token: token, decimals: 18, currency: JBCurrencyIds.ETH});
    }

    function pay(
        uint256 projectId,
        address,
        uint256 amount,
        address beneficiary,
        uint256,
        string calldata,
        bytes calldata
    )
        external
        payable
        returns (uint256)
    {
        paidValue += msg.value;
        paidProjectId = projectId;
        paidBeneficiary = beneficiary;
        assert(amount == msg.value);
        return 0;
    }
}

contract PublishBoundaryStore {
    uint256 public maxTierId;
    mapping(uint256 tierId => JB721Tier tier) internal _tierOf;

    function balanceOf(address, address) external pure returns (uint256) {
        return 0;
    }

    function addTier(JB721TierConfig calldata config) external {
        maxTierId++;
        _tierOf[maxTierId] = JB721Tier({
            // forge-lint: disable-next-line(unsafe-typecast)
            id: uint32(maxTierId),
            price: config.price,
            remainingSupply: config.initialSupply,
            initialSupply: config.initialSupply,
            votingUnits: 0,
            reserveFrequency: 0,
            reserveBeneficiary: address(0),
            encodedIpfsUri: config.encodedIpfsUri,
            category: config.category,
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

    function maxTierIdOf(address) external view returns (uint256) {
        return maxTierId;
    }

    function isTierRemoved(address, uint256) external pure returns (bool) {
        return false;
    }

    function tierOf(address, uint256 id, bool) external view returns (JB721Tier memory) {
        return _tierOf[id];
    }
}

contract PublishBoundaryHook {
    uint256 public immutable PROJECT_ID;
    IJB721TiersHookStore public immutable STORE;
    address public immutable owner;
    uint256 public adjustedTiers;
    uint256 public mintedNfts;

    constructor(uint256 projectId_, IJB721TiersHookStore store, address owner_) {
        PROJECT_ID = projectId_;
        STORE = store;
        owner = owner_;
    }

    function projectId() external view returns (uint256) {
        return PROJECT_ID;
    }

    function pricingContext() external pure returns (uint256, uint256) {
        return (JBCurrencyIds.ETH, 18);
    }

    function METADATA_ID_TARGET() external view returns (address) {
        return address(this);
    }

    function adjustTiers(JB721TierConfig[] calldata tiersToAdd, uint256[] calldata) external {
        adjustedTiers += tiersToAdd.length;
        for (uint256 i; i < tiersToAdd.length; i++) {
            PublishBoundaryStore(address(STORE)).addTier(tiersToAdd[i]);
        }
    }
}

contract RegressionPublishHookBoundaryTest is Test {
    function testMintFromRevertsWhenTerminalDoesNotInvokeHook() external {
        uint256 projectId = 2;
        uint256 feeProjectId = 1;
        uint256 price = 1 ether;
        uint256 fee = price / 20;
        address beneficiary = address(0xB0B);

        PublishBoundaryPermissions permissions = new PublishBoundaryPermissions();
        PublishBoundaryDirectory directory = new PublishBoundaryDirectory();
        PublishBoundaryTerminal projectTerminal = new PublishBoundaryTerminal();
        PublishBoundaryTerminal feeTerminal = new PublishBoundaryTerminal();
        PublishBoundaryStore store = new PublishBoundaryStore();
        PublishBoundaryHook hook =
            new PublishBoundaryHook(projectId, IJB721TiersHookStore(address(store)), address(this));

        directory.setTerminal(projectId, IJBTerminal(address(projectTerminal)));
        directory.setTerminal(feeProjectId, IJBTerminal(address(feeTerminal)));

        CTPublisher publisher = new CTPublisher(
            IJBDirectory(address(directory)),
            IJBPermissions(address(permissions)),
            feeProjectId,
            IPermit2(address(0)),
            address(0)
        );

        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: address(hook),
            category: 1,
            // forge-lint: disable-next-line(unsafe-typecast)
            minimumPrice: uint104(price),
            minimumTotalSupply: 1,
            maximumTotalSupply: 1,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });
        publisher.configurePostingCriteriaFor(allowedPosts);

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            // forge-lint: disable-next-line(unsafe-typecast)
            encodedIpfsUri: bytes32("post"),
            totalSupply: 1,
            // forge-lint: disable-next-line(unsafe-typecast)
            price: uint104(price),
            category: 1,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        vm.expectRevert(
            abi.encodeWithSelector(CTPublisher.CTPublisher_MintNotDelivered.selector, address(hook), beneficiary, 1, 0)
        );
        publisher.mintFrom{value: price + fee}(
            IJB721TiersHook(address(hook)),
            posts,
            JBConstants.NATIVE_TOKEN,
            price + fee,
            beneficiary,
            address(0xFEE),
            bytes("")
        );

        assertEq(hook.adjustedTiers(), 0, "tier creation rolled back");
        assertEq(projectTerminal.paidValue(), 0, "project payment rolled back");
        assertEq(feeTerminal.paidValue(), 0, "fee payment was never attempted");
        assertEq(hook.mintedNfts(), 0, "terminal never invoked hook minting");
    }
}
