// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";

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

contract NemesisProjects {
    uint256 public countValue;
    address public ownerOfProject;

    function setCount(uint256 count_) external {
        countValue = count_;
    }

    function count() external view returns (uint256) {
        return countValue;
    }

    function createFor(address owner_) external returns (uint256 projectId) {
        projectId = ++countValue;
        ownerOfProject = owner_;
    }

    function ownerOf(uint256) external view returns (address) {
        return ownerOfProject;
    }

    function transferFrom(address, address to, uint256) external {
        ownerOfProject = to;
    }
}

contract NemesisController {
    NemesisProjects public immutable PROJECTS;

    constructor(NemesisProjects projects_) {
        PROJECTS = projects_;
    }

    function launchRulesetsFor(
        uint256 projectId,
        string calldata,
        JBRulesetConfig[] calldata,
        JBTerminalConfig[] calldata,
        string calldata
    )
        external
        pure
        returns (uint256)
    {
        return projectId;
    }
}

contract NemesisSuckerRegistry {
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

contract NemesisPermissionedHook is JBPermissioned {
    address public immutable ownerAccount;
    uint256 public immutable projectId;
    address public adjustedBy;
    address public mintedBy;

    constructor(IJBPermissions permissions, address ownerAccount_, uint256 projectId_) JBPermissioned(permissions) {
        ownerAccount = ownerAccount_;
        projectId = projectId_;
    }

    function owner() external view returns (address) {
        return ownerAccount;
    }

    function adjustTiers(JB721TierConfig[] calldata, uint256[] calldata) external {
        _requirePermissionFrom(ownerAccount, projectId, JBPermissionIds.ADJUST_721_TIERS);
        adjustedBy = msg.sender;
    }

    function mintFor(uint16[] calldata, address) external returns (uint256[] memory tokenIds) {
        _requirePermissionFrom(ownerAccount, projectId, JBPermissionIds.MINT_721);
        mintedBy = msg.sender;
        tokenIds = new uint256[](0);
    }
}

contract NemesisHookDeployer {
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

contract NemesisStaleDeployerPermissionsTest is Test {
    JBPermissions internal permissions;
    NemesisProjects internal projects;
    NemesisHookDeployer internal hookDeployer;
    NemesisSuckerRegistry internal suckerRegistry;
    NemesisController internal controller;
    CTPublisher internal publisher;
    CTDeployer internal deployer;
    NemesisPermissionedHook internal hook;

    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");

    function setUp() public {
        permissions = new JBPermissions(address(0));
        projects = new NemesisProjects();
        projects.setCount(5);
        hookDeployer = new NemesisHookDeployer();
        suckerRegistry = new NemesisSuckerRegistry();
        publisher = new CTPublisher(IJBDirectory(makeAddr("directory")), permissions, 1, address(0));
        deployer = new CTDeployer(
            permissions,
            IJBProjects(address(projects)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            ICTPublisher(address(publisher)),
            IJBSuckerRegistry(address(suckerRegistry)),
            address(0)
        );
        hook = new NemesisPermissionedHook(permissions, address(deployer), 6);
        hookDeployer.setHook(IJB721TiersHook(address(hook)));
        controller = new NemesisController(projects);
    }

    function test_initialOwnerKeepsHookPermissionsAfterProjectNftTransferUntilClaim() public {
        CTProjectConfig memory config = CTProjectConfig({
            terminalConfigurations: new JBTerminalConfig[](0),
            projectUri: "ipfs://project",
            allowedPosts: new CTDeployerAllowedPost[](0),
            contractUri: "ipfs://contract",
            name: "Croptop",
            symbol: "CT",
            salt: bytes32(0)
        });

        CTSuckerDeploymentConfig memory suckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});

        deployer.deployProjectFor(ownerA, config, suckerConfig, IJBController(address(controller)));
        assertEq(projects.ownerOf(6), ownerA, "ownerA receives the project NFT");

        vm.prank(ownerA);
        projects.transferFrom(ownerA, ownerB, 6);
        assertEq(projects.ownerOf(6), ownerB, "ownerB is now the project owner");

        vm.prank(ownerA);
        hook.adjustTiers(new JB721TierConfig[](0), new uint256[](0));
        assertEq(hook.adjustedBy(), ownerA, "old project owner can still adjust deployer-owned hook");

        vm.prank(ownerA);
        hook.mintFor(new uint16[](0), ownerA);
        assertEq(hook.mintedBy(), ownerA, "old project owner can still use deployer-scoped mint permission");
    }
}
