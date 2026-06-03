// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// forge-lint: disable-next-line(unaliased-plain-import)
import "forge-std/Test.sol";
import {JBMetadataResolver} from "@bananapus/core-v6/src/libraries/JBMetadataResolver.sol";

import {MetadataResolverHelper} from "@bananapus/core-v6/test/helpers/MetadataResolverHelper.sol";

/// @notice Quick test to assert the creation of metadata while minting
/// @dev    This test is not meant to be exhaustive, but to ensure that the metadata is valid.
///         It uses a mock contract which only returns a metadata following the logic
///         of the CroptopPublisher contract during mint. This external contract is used to recreate the same
contract Test_MetadataGeneration_Unit is Test {
    /// @notice Create new metadata from _additionalPayMetadata and the data hook metadata containing the tiers to
    /// mint).
    /// @dev    Naming follows CroptopPublisher contract.
    function test_metadataBuilding() public {
        MetadataResolverHelper _resolverHelper = new MetadataResolverHelper();

        // The initial metadata passed to the terminal.
        bytes4[] memory _ids = new bytes4[](10);
        bytes[] memory _datas = new bytes[](10);

        for (uint256 _i; _i < _ids.length; _i++) {
            // forge-lint: disable-next-line(unsafe-typecast)
            _ids[_i] = bytes4(uint32(_i + 1 * 1000));
            _datas[_i] = abi.encode(
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes1(uint8(_i + 1)),
                uint32(69),
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes2(uint16(_i + 69)),
                bytes32(uint256(type(uint256).max))
            );
        }

        bytes memory _additionalPayMetadata = _resolverHelper.createMetadata(_ids, _datas);

        // The additional data hook metadata to include.
        bytes4 dataHookId = bytes4(bytes20(address(0xdeadbeef)));
        uint256[] memory tierIdsToMint = new uint256[](9);

        for (uint256 i = 0; i < 9; i++) {
            tierIdsToMint[i] = i + 1;
        }

        // Test: create the new metadata:
        bytes memory mintMetadata = JBMetadataResolver.addToMetadata({
            originalMetadata: _additionalPayMetadata, idToAdd: dataHookId, dataToAdd: abi.encode(true, tierIdsToMint)
        });

        bytes memory targetData;
        bool found;

        // Check: both data are present and correct?
        for (uint256 i = 0; i < _ids.length; i++) {
            (found, targetData) = JBMetadataResolver.getDataFor(_ids[i], mintMetadata);
            assertTrue(found, "metadata not found");
            assertEq(targetData, _datas[i], "metadata not equal");
        }

        (found, targetData) = JBMetadataResolver.getDataFor(dataHookId, mintMetadata);
        assertTrue(found, "data hook metadata not found");
        assertEq(targetData, abi.encode(true, tierIdsToMint), "data hook not equal");
    }
}
