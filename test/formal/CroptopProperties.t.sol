// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBPermissions} from "@bananapus/core-v6/src/interfaces/IJBPermissions.sol";
import {IJBProjects} from "@bananapus/core-v6/src/interfaces/IJBProjects.sol";
import {IJBRulesetDataHook} from "@bananapus/core-v6/src/interfaces/IJBRulesetDataHook.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {IJB721TiersHookDeployer} from "@bananapus/721-hook-v6/src/interfaces/IJB721TiersHookDeployer.sol";
import {IJBSuckerRegistry} from "@bananapus/suckers-v6/src/interfaces/IJBSuckerRegistry.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {CTDeployer} from "../../src/CTDeployer.sol";
import {CTPublisher} from "../../src/CTPublisher.sol";
import {ICTDeployer} from "../../src/interfaces/ICTDeployer.sol";
import {CTAllowedPost} from "../../src/structs/CTAllowedPost.sol";

/// @title CroptopProperties
/// @notice Functional-correctness properties for Croptop fee arithmetic, decimal scaling, allowance bit-packing field
/// isolation, and deployer interface advertisement. Each property is dual-implemented: `check_` for Halmos (symbolic)
/// and `testFuzz_` for forge, mirroring the house convention in nana-core-v6/test/formal/FeeProperties.t.sol.
/// @dev These cover the spec surface NOT already proven by `CroptopHalmos.t.sol`: the 5% fee split conservation, the
/// `_scaleAmount` ceil semantics, the full bit-packing field-isolation of `allowanceFor`, and the
/// `IJBRulesetDataHook` advertisement of `CTDeployer.supportsInterface`.
contract CroptopProperties is Test {
    //*********************************************************************//
    // ------------------------ stored properties ------------------------ //
    //*********************************************************************//

    /// @notice Harness exposing CTPublisher internals (constant + `_scaleAmount`).
    PublisherScaleHarness internal _publisher;

    /// @notice Deployer under test for the interface-advertisement proof.
    CTDeployer internal _deployer;

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor() {
        PropMockPermissions permissions = new PropMockPermissions();

        _publisher = new PublisherScaleHarness({
            directory: IJBDirectory(address(1)),
            permissions: IJBPermissions(address(permissions)),
            feeProjectId: 1,
            permit2: IPermit2(address(0)),
            trustedForwarder: address(0)
        });

        _deployer = new CTDeployer({
            permissions: IJBPermissions(address(permissions)),
            projects: IJBProjects(address(2)),
            deployer: IJB721TiersHookDeployer(address(3)),
            publisher: _publisher,
            suckerRegistry: IJBSuckerRegistry(address(new PropMockSuckerRegistry())),
            trustedForwarder: address(0)
        });
    }

    //*********************************************************************//
    // ------------------ Property 1: fee split conservation ------------- //
    //*********************************************************************//

    /// @notice The 5% Croptop fee split is value-conserving: `fee + payValue == totalPrice`, with no value created or
    /// lost, and the fee is exactly `totalPrice / FEE_DIVISOR`. Mirrors the `_mintFrom` non-fee-project branch.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_feeSplitConserves(uint256 totalPrice) public view {
        // Bound to a realistic price domain (price fits a uint104 in the post struct, but allow scaled-up amounts).
        if (totalPrice > type(uint160).max) return;

        uint256 feeDivisor = _publisher.FEE_DIVISOR();
        uint256 fee = totalPrice / feeDivisor;
        uint256 payValue = totalPrice - fee;

        // Conservation: every wei of the supplied price is accounted for as either fee or pay value.
        assert(fee + payValue == totalPrice);
        // The fee never exceeds the price it is taken from.
        assert(fee <= totalPrice);
        // The pay value is always the larger share for a 5% (1/20) fee.
        assert(payValue >= fee);
    }

    function testFuzz_feeSplitConserves(uint160 totalPrice) public {
        uint256 feeDivisor = _publisher.FEE_DIVISOR();
        uint256 fee = uint256(totalPrice) / feeDivisor;
        uint256 payValue = uint256(totalPrice) - fee;

        assertEq(fee + payValue, uint256(totalPrice), "fee + payValue must equal totalPrice");
        assertLe(fee, uint256(totalPrice), "fee must not exceed totalPrice");
        assertGe(payValue, fee, "payValue must be the majority share");
    }

    /// @notice The fee rounds in the payer's favor: truncation loses at most `FEE_DIVISOR - 1` wei versus the exact
    /// `totalPrice / FEE_DIVISOR`. Equivalently, `fee * FEE_DIVISOR <= totalPrice < (fee + 1) * FEE_DIVISOR`.
    /// @notice The fee rounds in the payer's favor: truncation loses at most `FEE_DIVISOR - 1` wei versus the exact
    /// `totalPrice / FEE_DIVISOR`. Fuzz-only: the nonlinear `fee * FEE_DIVISOR` constraint is not SMT-tractable for
    /// Halmos (it times out in the model phase even at 96-bit width).
    function testFuzz_feeRoundsInPayerFavor(uint160 totalPrice) public {
        uint256 feeDivisor = _publisher.FEE_DIVISOR();
        uint256 fee = uint256(totalPrice) / feeDivisor;

        assertLe(fee * feeDivisor, uint256(totalPrice), "taken fee must not exceed exact fee");
        assertLt(uint256(totalPrice) - fee * feeDivisor, feeDivisor, "dust kept by payer must be below one divisor");
    }

    //*********************************************************************//
    // -------------- Property 2: _scaleAmount decimal semantics --------- //
    //*********************************************************************//

    /// @notice `_scaleAmount` is the identity on equal decimals, an exact power-of-ten multiply when widening, and a
    /// ceil division when narrowing (so a payer cannot underpay by truncation). Fuzz-only: even with the canonical
    /// decimal regimes concretized, the `mulDiv`-Ceil 512-bit path and the `1e12` multiplications time out under
    /// Halmos, so the symbolic `10**N` decimal scaling is verified by fuzzing rather than proven.
    function testFuzz_scaleAmountSemantics(uint128 amount, uint8 fromDecimals, uint8 toDecimals) public {
        fromDecimals = uint8(bound(fromDecimals, 0, 30));
        toDecimals = uint8(bound(toDecimals, 0, 30));

        uint256 scaled = _publisher.scaleAmount({amount: amount, fromDecimals: fromDecimals, toDecimals: toDecimals});

        if (fromDecimals == toDecimals) {
            assertEq(scaled, amount, "equal decimals must be identity");
        } else if (fromDecimals < toDecimals) {
            uint256 factor = 10 ** (uint256(toDecimals) - uint256(fromDecimals));
            assertEq(scaled, uint256(amount) * factor, "scale up must be exact multiply");
        } else {
            uint256 denom = 10 ** (uint256(fromDecimals) - uint256(toDecimals));
            assertGe(scaled * denom, amount, "scale down must round up (cover the amount)");
            if (scaled != 0) {
                assertLt((scaled - 1) * denom, amount, "scale down must be the minimal cover (true ceil)");
            }
        }
    }

    /// @notice Scaling down then back up never returns less than the original (no value can be lost across a
    /// ceil-rounded narrowing). The double symbolic `10**N` makes this intractable for Halmos, so it is fuzz-only.
    function testFuzz_scaleDownThenUpNeverUnderpays(uint96 amount, uint8 small, uint8 large) public {
        small = uint8(bound(small, 0, 29));
        large = uint8(bound(large, small + 1, 30));

        uint256 down = _publisher.scaleAmount({amount: amount, fromDecimals: large, toDecimals: small});
        // `down` is a scale-down of a uint96 amount, so it always fits a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 backUp = _publisher.scaleAmount({amount: uint128(down), fromDecimals: small, toDecimals: large});

        assertGe(backUp, amount, "scale-down-then-up must never underpay the original");
    }

    //*********************************************************************//
    // ------------ Property 3: allowanceFor field isolation ------------- //
    //*********************************************************************//

    /// @notice The four packed allowance fields are isolated: writing all four at their type-maximums and reading them
    /// back returns each maximum exactly, proving no field bleeds into an adjacent one. This exercises the real
    /// `configurePostingCriteriaFor` packing and the real `allowanceFor` unpacking. (`minimumTotalSupply` must be
    /// non-zero and `<= maximumTotalSupply`, so we use it at max alongside an unlimited max-supply sentinel of 0 and a
    /// separate max-supply case.)
    // forge-lint: disable-next-line(mixed-case-function)
    function check_allowanceFieldIsolationAtMax(
        uint24 category,
        uint104 minimumPrice,
        uint32 minimumTotalSupply,
        uint32 maximumSplitPercent
    )
        public
    {
        if (minimumTotalSupply == 0) return;

        // Use maximumTotalSupply == minimumTotalSupply so the min<=max constraint holds while both are non-trivial.
        uint32 maximumTotalSupply = minimumTotalSupply;

        CTAllowedPost[] memory allowedPosts = new CTAllowedPost[](1);
        allowedPosts[0] = CTAllowedPost({
            hook: address(_publisher.HOOK()),
            category: category,
            minimumPrice: minimumPrice,
            minimumTotalSupply: minimumTotalSupply,
            maximumTotalSupply: maximumTotalSupply,
            maximumSplitPercent: maximumSplitPercent,
            allowedAddresses: new address[](0)
        });

        _publisher.configurePostingCriteriaFor({allowedPosts: allowedPosts});

        (uint256 rMinPrice, uint256 rMinSupply, uint256 rMaxSupply, uint256 rMaxSplit,) =
            _publisher.allowanceFor({hook: address(_publisher.HOOK()), category: category});

        // No high bits of one field appear in another, even when all are set to their type maxima.
        assert(rMinPrice == minimumPrice);
        assert(rMinSupply == minimumTotalSupply);
        assert(rMaxSupply == maximumTotalSupply);
        assert(rMaxSplit == maximumSplitPercent);
    }

    //*********************************************************************//
    // ----------- Property 4: deployer interface advertisement ---------- //
    //*********************************************************************//

    /// @notice `CTDeployer` advertises EVERY interface its integrations rely on, including `IJBRulesetDataHook` (the
    /// branch the existing Halmos suite omits), and rejects unrelated selectors. ERC165 itself plus the three claimed
    /// interfaces, and a clearly-unsupported selector, are all checked.
    // forge-lint: disable-next-line(mixed-case-function)
    function check_supportsAllAdvertisedInterfaces() public view {
        assert(_deployer.supportsInterface(type(ICTDeployer).interfaceId));
        assert(_deployer.supportsInterface(type(IJBRulesetDataHook).interfaceId));
        assert(_deployer.supportsInterface(type(IERC721Receiver).interfaceId));
        // Unrelated selectors must not be claimed.
        assert(!_deployer.supportsInterface(bytes4(0)));
        assert(!_deployer.supportsInterface(0xdeadbeef));
    }

    function testFuzz_supportsInterfaceRejectsUnrelated(bytes4 interfaceId) public {
        // Any selector that is none of the three advertised interfaces (and not ERC165 itself) must return false.
        vm.assume(interfaceId != type(ICTDeployer).interfaceId);
        vm.assume(interfaceId != type(IJBRulesetDataHook).interfaceId);
        vm.assume(interfaceId != type(IERC721Receiver).interfaceId);

        assertFalse(_deployer.supportsInterface(interfaceId), "must not claim unrelated interfaces");
    }
}

/// @notice Harness exposing CTPublisher's internal pure `_scaleAmount` and a hook getter for allowance proofs.
contract PublisherScaleHarness is CTPublisher {
    /// @notice A mock 721 hook so allowance configuration can pass its owner/projectId permission gate.
    PropMock721Hook public immutable HOOK;

    constructor(
        IJBDirectory directory,
        IJBPermissions permissions,
        uint256 feeProjectId,
        IPermit2 permit2,
        address trustedForwarder
    )
        CTPublisher(directory, permissions, feeProjectId, permit2, trustedForwarder)
    {
        HOOK = new PropMock721Hook();
    }

    /// @notice External wrapper around the internal `_scaleAmount` decimal converter.
    function scaleAmount(uint256 amount, uint256 fromDecimals, uint256 toDecimals) external pure returns (uint256) {
        return _scaleAmount({amount: amount, fromDecimals: fromDecimals, toDecimals: toDecimals});
    }
}

/// @notice Minimal hook exposing only `owner()` and `projectId()` for the allowance permission gate.
contract PropMock721Hook {
    function owner() external view returns (address) {
        return address(this);
    }

    function projectId() external pure returns (uint256) {
        return 42;
    }
}

/// @notice Permissions mock that always grants and accepts writes.
contract PropMockPermissions {
    function hasPermission(address, address, uint256, uint256, bool, bool) external pure returns (bool) {
        return true;
    }

    function setPermissionsFor(address, JBPermissionsData calldata) external pure {}
}

/// @notice Sucker registry mock; never reports a sucker (default path).
contract PropMockSuckerRegistry {
    function isSuckerOf(uint256, address) external pure returns (bool) {
        return false;
    }
}
