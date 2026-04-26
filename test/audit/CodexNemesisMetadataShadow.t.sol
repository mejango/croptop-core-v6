// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookStore} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookStore.sol";
import {JB721Tier} from "@bananapus/721-hook-v6/src/structs/JB721Tier.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSplit} from "@bananapus/core-v6/src/structs/JBSplit.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";
import {CTPost} from "../../src/structs/CTPost.sol";

contract MetadataShadowPermissions is IJBPermissions {
    // forge-lint: disable-next-line(mixed-case-function)
    function WILDCARD_PROJECT_ID() external pure returns (uint256) {
        return 0;
    }

    function permissionsOf(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function hasPermission(address, address, uint256, uint256, bool, bool) external pure returns (bool) {
        return true;
    }

    function hasPermissions(address, address, uint256, uint256[] calldata, bool, bool) external pure returns (bool) {
        return true;
    }

    function setPermissionsFor(address, JBPermissionsData calldata) external {}
}

contract MetadataShadowStore {
    function maxTierIdOf(address) external pure returns (uint256) {
        return 0;
    }

    function isTierRemoved(address, uint256) external pure returns (bool) {
        return false;
    }

    function tierOf(address, uint256, bool) external pure returns (JB721Tier memory tier) {
        return tier;
    }
}

contract MetadataShadowHook {
    uint256 public constant PROJECT_ID = 2;
    address public immutable METADATA_ID_TARGET;
    IJB721TiersHookStore public immutable STORE;
    address public immutable OWNER;

    constructor(IJB721TiersHookStore store_, address owner_, address metadataIdTarget_) {
        STORE = store_;
        OWNER = owner_;
        METADATA_ID_TARGET = metadataIdTarget_;
    }

    function adjustTiers(JB721TierConfig[] calldata, uint256[] calldata) external {}

    function owner() external view returns (address) {
        return OWNER;
    }
}

contract MetadataCapturingTerminal {
    address internal immutable METADATA_ID_TARGET;
    bool public found;
    bool public payerAllowsOverspending;
    uint256 public tierCount;
    uint16 public firstTierId;
    uint256 public totalReceived;

    constructor(address metadataIdTarget_) {
        METADATA_ID_TARGET = metadataIdTarget_;
    }

    function pay(
        uint256,
        address,
        uint256,
        address,
        uint256,
        string calldata,
        bytes calldata metadata
    )
        external
        payable
        returns (uint256)
    {
        totalReceived += msg.value;
        bytes4 id = JBMetadataResolver.getId({purpose: "pay", target: METADATA_ID_TARGET});
        bytes memory data;
        (found, data) = JBMetadataResolver.getDataFor({id: id, metadata: metadata});
        if (found) {
            uint16[] memory tierIds;
            (payerAllowsOverspending, tierIds) = abi.decode(data, (bool, uint16[]));
            tierCount = tierIds.length;
            if (tierIds.length != 0) firstTierId = tierIds[0];
        }
        return 0;
    }
}

contract MetadataNoopTerminal {
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

contract MetadataShadowDirectory {
    IJBTerminal public projectTerminal;
    IJBTerminal public feeTerminal;

    function setTerminals(IJBTerminal projectTerminal_, IJBTerminal feeTerminal_) external {
        projectTerminal = projectTerminal_;
        feeTerminal = feeTerminal_;
    }

    function primaryTerminalOf(uint256 projectId, address) external view returns (IJBTerminal) {
        return projectId == 1 ? feeTerminal : projectTerminal;
    }
}

contract CodexNemesisMetadataShadowTest is Test {
    function test_additionalPayMetadataCanShadowPublisherMintMetadata() public {
        address metadataIdTarget = address(0xBEEF);
        MetadataShadowPermissions permissions = new MetadataShadowPermissions();
        MetadataShadowDirectory directory = new MetadataShadowDirectory();
        MetadataShadowStore store = new MetadataShadowStore();
        MetadataShadowHook hook =
            new MetadataShadowHook(IJB721TiersHookStore(address(store)), address(this), metadataIdTarget);
        MetadataCapturingTerminal projectTerminal = new MetadataCapturingTerminal(metadataIdTarget);
        MetadataNoopTerminal feeTerminal = new MetadataNoopTerminal();
        directory.setTerminals(IJBTerminal(address(projectTerminal)), IJBTerminal(address(feeTerminal)));

        CTPublisher publisher = new CTPublisher(IJBDirectory(address(directory)), permissions, 1, address(0));

        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: address(hook),
            category: 1,
            minimumPrice: 100,
            minimumTotalSupply: 1,
            maximumTotalSupply: type(uint32).max,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });
        publisher.configurePostingCriteriaFor(allowedPosts);

        CTPost[] memory posts = new CTPost[](1);
        posts[0] = CTPost({
            encodedIPFSUri: keccak256("publisher-validated-post"),
            totalSupply: 1,
            price: 100,
            category: 1,
            splitPercent: 0,
            splits: new JBSplit[](0)
        });

        uint16[] memory forgedTierIds = new uint16[](1);
        forgedTierIds[0] = 2;
        bytes4[] memory ids = new bytes4[](1);
        bytes[] memory datas = new bytes[](1);
        ids[0] = JBMetadataResolver.getId({purpose: "pay", target: metadataIdTarget});
        datas[0] = abi.encode(true, forgedTierIds);
        bytes memory shadowingMetadata = JBMetadataResolver.createMetadata(ids, datas);

        publisher.mintFrom{value: 105}(
            IJB721TiersHook(address(hook)), posts, address(this), address(this), shadowingMetadata, ""
        );

        assertEq(
            publisher.tierIdForEncodedIPFSUriOf(address(hook), posts[0].encodedIPFSUri),
            1,
            "publisher validated and cached tier 1"
        );
        assertTrue(projectTerminal.found(), "terminal/parser should find pay metadata");
        assertEq(projectTerminal.tierCount(), 1, "forged metadata contains one tier");
        assertEq(projectTerminal.firstTierId(), 2, "parser used caller-supplied tier 2 instead of publisher tier 1");
    }
}
