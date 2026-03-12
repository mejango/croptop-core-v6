// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdJson} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {CTPublisher} from "../../src/CTPublisher.sol";
import {CTDeployer} from "../../src/CTDeployer.sol";
import {CTProjectOwner} from "../../src/CTProjectOwner.sol";

struct CroptopDeployment {
    CTPublisher publisher;
    CTDeployer deployer;
    CTProjectOwner project_owner;
}

library CroptopDeploymentLib {
    // Cheat code address, 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D.
    address internal constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDRESS);

    function getDeployment(string memory path) internal view returns (CroptopDeployment memory deployment) {
        return getDeployment(path, _getNetworkName(block.chainid));
    }

    function _getNetworkName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 1) return "ethereum";
        if (chainId == 10) return "optimism";
        if (chainId == 8453) return "base";
        if (chainId == 42161) return "arbitrum";
        if (chainId == 11155111) return "sepolia";
        if (chainId == 11155420) return "optimism_sepolia";
        if (chainId == 84532) return "base_sepolia";
        if (chainId == 421614) return "arbitrum_sepolia";
        revert("Unsupported chain ID");
    }

    function getDeployment(
        string memory path,
        string memory network_name
    )
        internal
        view
        returns (CroptopDeployment memory deployment)
    {
        deployment.publisher = CTPublisher(_getDeploymentAddress(path, "croptop-core-v6", network_name, "CTPublisher"));
        deployment.deployer = CTDeployer(_getDeploymentAddress(path, "croptop-core-v6", network_name, "CTDeployer"));
        deployment.project_owner =
            CTProjectOwner(_getDeploymentAddress(path, "croptop-core-v6", network_name, "CTProjectOwner"));
    }

    /// @notice Get the address of a contract that was deployed by the Deploy script.
    /// @dev Reverts if the contract was not found.
    /// @param path The path to the deployment file.
    /// @param contractName The name of the contract to get the address of.
    /// @return The address of the contract.
    function _getDeploymentAddress(
        string memory path,
        string memory project_name,
        string memory network_name,
        string memory contractName
    )
        internal
        view
        returns (address)
    {
        string memory deploymentJson =
            vm.readFile(string.concat(path, project_name, "/", network_name, "/", contractName, ".json"));
        return stdJson.readAddress(deploymentJson, ".address");
    }
}
