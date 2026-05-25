// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {JBController} from "@bananapus/core-v6/src/JBController.sol";
import {JBDirectory} from "@bananapus/core-v6/src/JBDirectory.sol";
import {JBFeelessAddresses} from "@bananapus/core-v6/src/JBFeelessAddresses.sol";
import {JBFundAccessLimits} from "@bananapus/core-v6/src/JBFundAccessLimits.sol";
import {JBMultiTerminal} from "@bananapus/core-v6/src/JBMultiTerminal.sol";
import {JBPermissions} from "@bananapus/core-v6/src/JBPermissions.sol";
import {JBPrices} from "@bananapus/core-v6/src/JBPrices.sol";
import {JBProjects} from "@bananapus/core-v6/src/JBProjects.sol";
import {JBRulesets} from "@bananapus/core-v6/src/JBRulesets.sol";
import {JBSplits} from "@bananapus/core-v6/src/JBSplits.sol";
import {JBTerminalStore} from "@bananapus/core-v6/src/JBTerminalStore.sol";
import {JBTokens} from "@bananapus/core-v6/src/JBTokens.sol";

import {SphinxConstants, NetworkInfo} from "@sphinx-labs/contracts/contracts/foundry/SphinxConstants.sol";

struct CoreDeployment {
    JBPermissions permissions;
    JBProjects projects;
    JBDirectory directory;
    JBSplits splits;
    JBRulesets rulesets;
    JBController controller;
    JBMultiTerminal terminal;
    JBTerminalStore terminalStore;
    JBPrices prices;
    JBFeelessAddresses feeless;
    JBFundAccessLimits fundAccess;
    JBTokens tokens;
    address trustedForwarder;
}

library CoreDeploymentLib {
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    // forge-lint: disable-next-line(screaming-snake-case-const)
    Vm internal constant vm = Vm(VM_ADDRESS);
    string internal constant PROJECT_NAME = "nana-core-v6";

    function getDeployment(string memory path) internal returns (CoreDeployment memory deployment) {
        uint256 chainId = block.chainid;

        SphinxConstants sphinxConstants = new SphinxConstants();
        NetworkInfo[] memory networks = sphinxConstants.getNetworkInfoArray();

        for (uint256 i; i < networks.length; i++) {
            if (networks[i].chainId == chainId) return getDeployment({path: path, networkName: networks[i].name});
        }

        revert("ChainID is not (currently) supported by Sphinx.");
    }

    function getDeployment(
        string memory path,
        string memory networkName
    )
        internal
        returns (CoreDeployment memory deployment)
    {
        deployment.permissions = JBPermissions(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBPermissions"
            })
        );

        deployment.projects = JBProjects(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBProjects"
            })
        );

        deployment.directory = JBDirectory(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBDirectory"
            })
        );

        deployment.splits = JBSplits(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBSplits"
            })
        );

        deployment.rulesets = JBRulesets(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBRulesets"
            })
        );

        deployment.controller = JBController(
            _tryGetDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBController"
            })
        );

        deployment.terminal = JBMultiTerminal(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBMultiTerminal"
            })
        );

        deployment.terminalStore = JBTerminalStore(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBTerminalStore"
            })
        );

        deployment.prices = JBPrices(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBPrices"
            })
        );

        deployment.feeless = JBFeelessAddresses(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBFeelessAddresses"
            })
        );

        deployment.fundAccess = JBFundAccessLimits(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBFundAccessLimits"
            })
        );

        deployment.tokens = JBTokens(
            _getDeploymentAddress({
                path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "JBTokens"
            })
        );

        deployment.trustedForwarder = _getDeploymentAddress({
            path: path, projectName: PROJECT_NAME, networkName: networkName, contractName: "ERC2771Forwarder"
        });
    }

    function _getDeploymentAddress(
        string memory path,
        string memory projectName,
        string memory networkName,
        string memory contractName
    )
        internal
        view
        returns (address)
    {
        string memory deploymentJson =
        // forge-lint: disable-next-line(unsafe-cheatcode)
        vm.readFile(string.concat(path, projectName, "/", networkName, "/", contractName, ".json"));
        return stdJson.readAddress({json: deploymentJson, key: ".address"});
    }

    function _tryGetDeploymentAddress(
        string memory path,
        string memory projectName,
        string memory networkName,
        string memory contractName
    )
        internal
        returns (address)
    {
        string memory filePath = string.concat(path, projectName, "/", networkName, "/", contractName, ".json");
        // forge-lint: disable-next-line(unsafe-cheatcode)
        if (!vm.exists(filePath)) return address(0);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return stdJson.readAddress({json: vm.readFile(filePath), key: ".address"});
    }
}
