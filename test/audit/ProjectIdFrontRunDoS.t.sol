// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

contract ProjectIdFrontRunDoSTest is Test {
    function test_vulnerableCountBasedLauncherCanBeFrontRun() public {
        MockProjects projects = new MockProjects(41, 43);
        MockController controller = new MockController(43);
        MockHookDeployer hookDeployer = new MockHookDeployer();
        VulnerableCTDeployerHarness harness = new VulnerableCTDeployerHarness(projects, hookDeployer);

        vm.expectRevert();
        harness.deployProjectFor(controller);
    }

    function test_reservedProjectIdCannotBeInvalidatedByEarlierCreations() public {
        MockProjects projects = new MockProjects(41, 43);
        MockController controller = new MockController(43);
        MockHookDeployer hookDeployer = new MockHookDeployer();
        FixedCTDeployerHarness harness = new FixedCTDeployerHarness(projects, hookDeployer);

        uint256 projectId = harness.deployProjectFor(controller);

        assertEq(projectId, 43);
        assertEq(projects.lastOwner(), address(harness));
        assertEq(hookDeployer.lastHookProjectId(), 43);
        assertEq(controller.lastLaunchedProjectId(), 43);
    }
}

contract VulnerableCTDeployerHarness {
    MockProjects internal immutable PROJECTS;
    MockHookDeployer internal immutable DEPLOYER;

    constructor(MockProjects projects, MockHookDeployer deployer) {
        PROJECTS = projects;
        DEPLOYER = deployer;
    }

    function deployProjectFor(MockController controller) external returns (uint256 projectId) {
        projectId = PROJECTS.count() + 1;
        DEPLOYER.deployHookFor(projectId);
        assert(projectId == controller.launchProjectFor());
    }
}

contract FixedCTDeployerHarness {
    MockProjects internal immutable PROJECTS;
    MockHookDeployer internal immutable DEPLOYER;

    constructor(MockProjects projects, MockHookDeployer deployer) {
        PROJECTS = projects;
        DEPLOYER = deployer;
    }

    function deployProjectFor(MockController controller) external returns (uint256 projectId) {
        projectId = PROJECTS.createFor(address(this));
        DEPLOYER.deployHookFor(projectId);
        controller.launchRulesetsFor(projectId);
    }
}

contract MockProjects {
    uint256 internal immutable _count;
    uint256 internal immutable _reservedId;

    address public lastOwner;

    constructor(uint256 count_, uint256 reservedId_) {
        _count = count_;
        _reservedId = reservedId_;
    }

    function count() external view returns (uint256) {
        return _count;
    }

    function createFor(address owner) external returns (uint256) {
        lastOwner = owner;
        return _reservedId;
    }
}

contract MockController {
    uint256 internal immutable _launchedId;

    uint256 public lastLaunchedProjectId;

    constructor(uint256 launchedId_) {
        _launchedId = launchedId_;
    }

    function launchProjectFor() external view returns (uint256) {
        return _launchedId;
    }

    function launchRulesetsFor(uint256 projectId) external {
        lastLaunchedProjectId = projectId;
    }
}

contract MockHookDeployer {
    uint256 public lastHookProjectId;

    function deployHookFor(uint256 projectId) external {
        lastHookProjectId = projectId;
    }
}
