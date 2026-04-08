// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {CTProjectOwner} from "../../src/CTProjectOwner.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";
import {ICTDeployer} from "../../src/interfaces/ICTDeployer.sol";
import {ICTProjectOwner} from "../../src/interfaces/ICTProjectOwner.sol";
import {ICTPublisher} from "../../src/interfaces/ICTPublisher.sol";
import {CTDeployerAllowedPost} from "../../src/structs/CTDeployerAllowedPost.sol";
import {CTProjectConfig} from "../../src/structs/CTProjectConfig.sol";
import {CTSuckerDeploymentConfig} from "../../src/structs/CTSuckerDeploymentConfig.sol";

contract BurnLockMockProjects {
    uint256 public countValue;
    mapping(uint256 => address) public ownerOfProject;

    function setCount(uint256 count_) external {
        countValue = count_;
    }

    function count() external view returns (uint256) {
        return countValue;
    }

    function mintFor(address owner_, uint256 projectId) external {
        ownerOfProject[projectId] = owner_;
        countValue = projectId;
    }

    function ownerOf(uint256 projectId) external view returns (address) {
        return ownerOfProject[projectId];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOfProject[tokenId] == from, "wrong from");
        ownerOfProject[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOfProject[tokenId] == from, "wrong from");
        ownerOfProject[tokenId] = to;
        IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
    }
}

contract BurnLockMockController {
    BurnLockMockProjects public immutable PROJECTS;
    uint256 public immutable NEXT_PROJECT_ID;

    constructor(BurnLockMockProjects projects_, uint256 nextProjectId_) {
        PROJECTS = projects_;
        NEXT_PROJECT_ID = nextProjectId_;
    }

    function launchProjectFor(
        address owner,
        string calldata,
        JBRulesetConfig[] calldata,
        JBTerminalConfig[] calldata,
        string calldata
    )
        external
        returns (uint256)
    {
        PROJECTS.mintFor(owner, NEXT_PROJECT_ID);
        return NEXT_PROJECT_ID;
    }
}

contract BurnLockMockSuckerRegistry {
    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }

    function deploySuckersFor(
        uint256,
        bytes32,
        JBSuckerDeployerConfig[] calldata
    )
        external
        pure
        returns (address[] memory suckers)
    {
        return suckers;
    }
}

contract BurnLockPermissionedHook is JBPermissioned {
    address public immutable OWNER_ACCOUNT;
    uint256 public immutable HOOK_PROJECT_ID;
    bool public adjusted;

    constructor(IJBPermissions permissions, address ownerAccount_, uint256 projectId_) JBPermissioned(permissions) {
        OWNER_ACCOUNT = ownerAccount_;
        HOOK_PROJECT_ID = projectId_;
    }

    function PROJECT_ID() external view returns (uint256) {
        return HOOK_PROJECT_ID;
    }

    function owner() external view returns (address) {
        return OWNER_ACCOUNT;
    }

    function jbOwner() external view returns (address, uint88, uint8) {
        return (OWNER_ACCOUNT, 0, 0);
    }

    function transferOwnershipToProject(uint256 newProjectId) external {
        // No-op for mock.
    }

    function adjustTiers(JB721TierConfig[] calldata, uint256[] calldata) external {
        _requirePermissionFrom(OWNER_ACCOUNT, HOOK_PROJECT_ID, JBPermissionIds.ADJUST_721_TIERS);
        adjusted = true;
    }
}

contract BurnLockMockHookDeployer {
    IJB721TiersHook public hook;

    function setHook(IJB721TiersHook hook_) external {
        hook = hook_;
    }

    function deployHookFor(
        uint256,
        JBDeploy721TiersHookConfig calldata,
        bytes32
    )
        external
        view
        returns (IJB721TiersHook)
    {
        return hook;
    }
}

contract BurnLockOwnershipBypassTest is Test {
    JBPermissions permissions;
    BurnLockMockProjects projects;
    BurnLockMockHookDeployer hookDeployer;
    BurnLockMockSuckerRegistry suckerRegistry;
    BurnLockMockController controller;
    CTPublisher publisher;
    CTDeployer deployer;
    CTProjectOwner projectOwner;
    BurnLockPermissionedHook hook;

    address owner = makeAddr("owner");
    uint256 constant PROJECT_ID = 6;

    function setUp() public {
        permissions = new JBPermissions(address(0));
        projects = new BurnLockMockProjects();
        projects.setCount(PROJECT_ID - 1);
        hookDeployer = new BurnLockMockHookDeployer();
        suckerRegistry = new BurnLockMockSuckerRegistry();
        publisher = new CTPublisher(IJBDirectory(makeAddr("directory")), permissions, 1, address(0));
        deployer = new CTDeployer(
            permissions,
            IJBProjects(address(projects)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            ICTPublisher(address(publisher)),
            IJBSuckerRegistry(address(suckerRegistry)),
            address(0)
        );
        projectOwner =
            new CTProjectOwner(ICTDeployer(address(deployer)), permissions, IJBProjects(address(projects)), publisher);
        hook = new BurnLockPermissionedHook(permissions, address(deployer), PROJECT_ID);
        hookDeployer.setHook(IJB721TiersHook(address(hook)));
        controller = new BurnLockMockController(projects, PROJECT_ID);
    }

    /// @notice Transferring a project to CTProjectOwner without first calling claimCollectionOwnershipOf must revert.
    function test_burnLockWithoutClaimReverts() public {
        CTDeployerAllowedPost[] memory allowedPosts = new CTDeployerAllowedPost[](1);
        allowedPosts[0] = CTDeployerAllowedPost({
            category: 1,
            minimumPrice: 1 ether,
            minimumTotalSupply: 10,
            maximumTotalSupply: 10,
            maximumSplitPercent: 0,
            allowedAddresses: new address[](0)
        });

        CTProjectConfig memory config = CTProjectConfig({
            terminalConfigurations: new JBTerminalConfig[](0),
            projectUri: "ipfs://project",
            allowedPosts: allowedPosts,
            contractUri: "ipfs://contract",
            name: "Croptop",
            symbol: "CT",
            salt: bytes32(0)
        });

        CTSuckerDeploymentConfig memory suckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});

        deployer.deployProjectFor(owner, config, suckerConfig, IJBController(address(controller)));

        assertEq(projects.ownerOfProject(PROJECT_ID), owner, "owner should receive the project NFT");
        assertEq(hook.OWNER_ACCOUNT(), address(deployer), "hook should still be owned by CTDeployer");

        // The transfer should revert because claimCollectionOwnershipOf was never called.
        vm.prank(owner);
        vm.expectRevert(ICTProjectOwner.CTProjectOwner_HookNotClaimed.selector);
        projects.safeTransferFrom(owner, address(projectOwner), PROJECT_ID);
    }
}
