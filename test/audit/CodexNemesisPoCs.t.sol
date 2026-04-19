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
import {JBSuckerRegistry} from "@bananapus/suckers-v6/src/JBSuckerRegistry.sol";
import {JBSuckerDeployerConfig} from "@bananapus/suckers-v6/src/structs/JBSuckerDeployerConfig.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";
import {ICTPublisher} from "../../src/interfaces/ICTPublisher.sol";
import {CTDeployerAllowedPost} from "../../src/structs/CTDeployerAllowedPost.sol";
import {CTProjectConfig} from "../../src/structs/CTProjectConfig.sol";
import {CTSuckerDeploymentConfig} from "../../src/structs/CTSuckerDeploymentConfig.sol";

contract NemesisMockProjects {
    uint256 public countValue;
    mapping(uint256 => address) internal _ownerOf;

    function setCount(uint256 count_) external {
        countValue = count_;
    }

    function setOwner(uint256 projectId, address owner_) external {
        _ownerOf[projectId] = owner_;
    }

    function count() external view returns (uint256) {
        return countValue;
    }

    function ownerOf(uint256 projectId) external view returns (address) {
        return _ownerOf[projectId];
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_ownerOf[tokenId] == from, "wrong from");
        _ownerOf[tokenId] = to;
    }
}

contract NemesisMockController {
    NemesisMockProjects public immutable PROJECTS;
    uint256 public immutable nextProjectId;

    constructor(NemesisMockProjects projects_, uint256 nextProjectId_) {
        PROJECTS = projects_;
        nextProjectId = nextProjectId_;
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
        PROJECTS.setOwner(nextProjectId, owner);
        return nextProjectId;
    }
}

contract NemesisPermissionedHook is JBPermissioned {
    address public immutable ownerAccount;
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

contract NemesisMockHookDeployer {
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

contract NemesisNoopSuckerRegistry {
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

contract NemesisMockDirectory {
    IJBProjects public immutable PROJECTS;

    constructor(IJBProjects projects_) {
        PROJECTS = projects_;
    }
}

contract CodexNemesisPoCs is Test {
    JBPermissions permissions;
    NemesisMockProjects projects;
    NemesisMockHookDeployer hookDeployer;
    NemesisMockController controller;
    CTPublisher publisher;
    CTDeployer deployer;
    NemesisPermissionedHook hook;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        permissions = new JBPermissions(address(0));
        projects = new NemesisMockProjects();
        projects.setCount(5);

        hookDeployer = new NemesisMockHookDeployer();
        publisher = new CTPublisher(IJBDirectory(makeAddr("directory")), permissions, 1, address(0));
        deployer = new CTDeployer(
            permissions,
            IJBProjects(address(projects)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            ICTPublisher(address(publisher)),
            IJBSuckerRegistry(address(new NemesisNoopSuckerRegistry())),
            address(0)
        );

        hook = new NemesisPermissionedHook(permissions, address(deployer), 6);
        hookDeployer.setHook(IJB721TiersHook(address(hook)));
        controller = new NemesisMockController(projects, 6);
    }

    function test_oldProjectOwnerRetainsHookControlAfterProjectNftTransferUntilClaim() public {
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

        deployer.deployProjectFor(alice, config, suckerConfig, IJBController(address(controller)));
        assertEq(projects.ownerOf(6), alice, "alice should receive the project NFT");

        projects.transferFrom(alice, bob, 6);
        assertEq(projects.ownerOf(6), bob, "bob should own the project NFT after transfer");

        JB721TierConfig[] memory arbitraryTiers = new JB721TierConfig[](0);
        uint256[] memory removals = new uint256[](0);

        vm.prank(alice);
        NemesisPermissionedHook(address(hook)).adjustTiers(arbitraryTiers, removals);

        assertTrue(
            hook.adjusted(),
            "the previous owner should still be able to mutate hook state until the new NFT owner explicitly claims"
        );
    }

    function test_deploySuckersHelperBreaksAfterOwnershipTransferBecauseRegistrySeesCtDeployerAsCaller() public {
        NemesisMockDirectory directory = new NemesisMockDirectory(IJBProjects(address(projects)));
        JBSuckerRegistry registry = new JBSuckerRegistry(IJBDirectory(address(directory)), permissions, address(this), address(0));

        deployer = new CTDeployer(
            permissions,
            IJBProjects(address(projects)),
            IJB721TiersHookDeployer(address(hookDeployer)),
            ICTPublisher(address(publisher)),
            IJBSuckerRegistry(address(registry)),
            address(0)
        );

        hook = new NemesisPermissionedHook(permissions, address(deployer), 6);
        hookDeployer.setHook(IJB721TiersHook(address(hook)));

        CTProjectConfig memory config = CTProjectConfig({
            terminalConfigurations: new JBTerminalConfig[](0),
            projectUri: "ipfs://project",
            allowedPosts: new CTDeployerAllowedPost[](0),
            contractUri: "ipfs://contract",
            name: "Croptop",
            symbol: "CT",
            salt: bytes32(0)
        });

        CTSuckerDeploymentConfig memory emptySuckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32(0)});
        deployer.deployProjectFor(alice, config, emptySuckerConfig, IJBController(address(controller)));

        CTSuckerDeploymentConfig memory laterSuckerConfig =
            CTSuckerDeploymentConfig({deployerConfigurations: new JBSuckerDeployerConfig[](0), salt: bytes32("later")});

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                JBPermissioned.JBPermissioned_Unauthorized.selector,
                alice,
                address(deployer),
                6,
                JBPermissionIds.DEPLOY_SUCKERS
            )
        );
        deployer.deploySuckersFor(6, laterSuckerConfig);
    }
}
