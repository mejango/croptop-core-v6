// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {JBDeploy721TiersHookConfig} from "@bananapus/721-hook-v6/src/structs/JBDeploy721TiersHookConfig.sol";
import {IJB721TiersHook} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHook.sol";
import {JB721TierConfig} from "@bananapus/721-hook-v6/src/structs/JB721TierConfig.sol";
import {JBPermissioned} from "@bananapus/core-v6/src/abstract/JBPermissioned.sol";
import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBRulesetConfig} from "@bananapus/core-v6/src/structs/JBRulesetConfig.sol";
import {JBTerminalConfig} from "@bananapus/core-v6/src/structs/JBTerminalConfig.sol";
import {JBPermissionIds} from "@bananapus/permission-ids-v6/src/JBPermissionIds.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";
import {ICTPublisher} from "../../src/interfaces/ICTPublisher.sol";
import {CTDeployerAllowedPost} from "../../src/structs/CTDeployerAllowedPost.sol";
import {CTProjectConfig} from "../../src/structs/CTProjectConfig.sol";
import {CTSuckerDeploymentConfig} from "../../src/structs/CTSuckerDeploymentConfig.sol";

contract MockProjects {
    uint256 public countValue;
    address public ownerOfProject;

    function setCount(uint256 count_) external {
        countValue = count_;
    }

    function setOwner(address owner_) external {
        ownerOfProject = owner_;
    }

    function count() external view returns (uint256) {
        return countValue;
    }

    function ownerOf(uint256) external view returns (address) {
        return ownerOfProject;
    }

    function transferFrom(address, address to, uint256) external {
        ownerOfProject = to;
    }
}

contract MockController {
    MockProjects public immutable PROJECTS;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable nextProjectId;

    constructor(MockProjects projects_, uint256 nextProjectId_) {
        PROJECTS = projects_;
        nextProjectId = nextProjectId_;
    }

    function launchProjectFor(
        address,
        string calldata,
        JBRulesetConfig[] calldata,
        JBTerminalConfig[] calldata,
        string calldata
    )
        external
        view
        returns (uint256)
    {
        return nextProjectId;
    }
}

contract MockSuckerRegistry {
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

contract PermissionedHook is JBPermissioned {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address public immutable ownerAccount;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint256 public immutable projectId;
    bool public adjusted;

    constructor(IJBPermissions permissions, address ownerAccount_, uint256 projectId_) JBPermissioned(permissions) {
        ownerAccount = ownerAccount_;
        projectId = projectId_;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function PROJECT_ID() external view returns (uint256) {
        return projectId;
    }

    function owner() external view returns (address) {
        return ownerAccount;
    }

    function adjustTiers(JB721TierConfig[] calldata, uint256[] calldata) external {
        _requirePermissionFrom(ownerAccount, projectId, JBPermissionIds.ADJUST_721_TIERS);
        adjusted = true;
    }
}

contract MockHookDeployer {
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

contract DeployerPermissionBypassTest is Test {
    JBPermissions permissions;
    MockProjects projects;
    MockHookDeployer hookDeployer;
    MockSuckerRegistry suckerRegistry;
    MockController controller;
    CTPublisher publisher;
    CTDeployer deployer;
    PermissionedHook hook;

    address owner = makeAddr("owner");

    function setUp() public {
        permissions = new JBPermissions(address(0));
        projects = new MockProjects();
        projects.setCount(5);
        hookDeployer = new MockHookDeployer();
        suckerRegistry = new MockSuckerRegistry();
        publisher = new CTPublisher(IJBDirectory(makeAddr("directory")), permissions, 1, address(0));
        deployer = new CTDeployer(
            permissions,
            IJBProjects(address(projects)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            ICTPublisher(address(publisher)),
            IJBSuckerRegistry(address(suckerRegistry)),
            address(0)
        );
        hook = new PermissionedHook(permissions, address(deployer), 6);
        hookDeployer.setHook(IJB721TiersHook(address(hook)));
        controller = new MockController(projects, 6);
    }

    function test_projectOwnerCannotBypassCroptopAndCallHookDirectlyBeforeClaim() public {
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

        assertEq(projects.ownerOf(6), owner, "deployment should hand the project NFT to the owner");

        JB721TierConfig[] memory arbitraryTiers = new JB721TierConfig[](0);
        uint256[] memory removals = new uint256[](0);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                address(deployer),
                owner,
                6,
                JBPermissionIds.ADJUST_721_TIERS
            )
        );
        PermissionedHook(address(hook)).adjustTiers(arbitraryTiers, removals);

        assertFalse(hook.adjusted(), "project owner must claim collection ownership before direct hook control");
    }
}
