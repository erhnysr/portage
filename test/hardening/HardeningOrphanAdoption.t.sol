// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HardeningBase} from "./HardeningBase.sol";
import {PortageRouter} from "../../contracts/periphery/PortageRouter.sol";
import {PayoutMeta} from "../../contracts/lib/PayoutMetaLib.sol";

/// @notice Hardening B: USDC that reaches the router outside the forwarder (an orphaned mint
///         with destinationCaller unset, or a direct transfer) can be brought under quarantine by
///         the governor and then refunded or credited, without touching existing quarantine.
contract HardeningOrphanAdoptionTest is HardeningBase {
    bytes32 constant GHOST = keccak256("ghost");

    function _orphanMint(uint256 value, bytes32 salt) internal returns (bytes32 sh) {
        SpecParams memory p = _spec(value, salt, address(0)); // destinationCaller unset
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        vm.prank(attacker);
        minter.gatewayMint(att, sig); // anyone can mint it straight to the router
        sh = _specHash(p);
    }

    function _quarantineViaForwarder(uint256 value, bytes32 salt) internal returns (bytes32 sh) {
        SpecParams memory p = _spec(value, salt, address(forwarder));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        sh = _specHash(p);
        PayoutMeta memory meta = _meta();
        meta.appId = GHOST; // unregistered -> quarantined
        bytes memory metaSig = _signMeta(sh, meta);
        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, sig, meta, metaSig);
    }

    function test_adoptOrphan_thenRefund() public {
        bytes32 sh = _orphanMint(7e6, keccak256("o1"));
        assertEq(router.quarantinedTotal(), 0);

        vm.prank(governor);
        router.adoptOrphan(sh, 7e6);
        assertEq(router.quarantined(sh), 7e6);
        assertEq(router.quarantinedTotal(), 7e6);
        assertTrue(router.processed(sh));

        vm.prank(governor);
        router.withdrawQuarantine(sh, depositor);
        assertEq(usdc.balanceOf(depositor), 7e6);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_adoptOrphan_thenResolveToApp() public {
        bytes32 sh = _orphanMint(4e6, keccak256("o2"));
        vm.startPrank(governor);
        router.adoptOrphan(sh, 4e6);
        router.resolveQuarantineToApp(sh, APP, ARENA);
        vm.stopPrank();
        assertEq(ledger.balanceOf(APP, ARENA), 4e6);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_adoptOrphan_cannotTouchExistingQuarantine() public {
        bytes32 q = _quarantineViaForwarder(5e6, keccak256("q1")); // 5e6 legitimately quarantined
        bytes32 sh = _orphanMint(2e6, keccak256("o3")); // 2e6 orphaned

        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(PortageRouter.ExceedsUnaccounted.selector, 3e6, 2e6));
        router.adoptOrphan(sh, 3e6);

        vm.expectRevert(abi.encodeWithSelector(PortageRouter.AlreadyProcessed.selector, q));
        router.adoptOrphan(q, 1); // an id already handled by the forwarder

        router.adoptOrphan(sh, 2e6);
        vm.stopPrank();
        assertEq(router.quarantined(q), 5e6, "existing entry untouched");
        assertEq(router.quarantinedTotal(), 7e6);
        assertEq(usdc.balanceOf(address(router)), router.quarantinedTotal());
    }

    function test_adoptOrphan_onlyGovernor_andNonZero() public {
        bytes32 sh = _orphanMint(1e6, keccak256("o4"));
        vm.prank(attacker);
        vm.expectRevert();
        router.adoptOrphan(sh, 1e6);

        vm.prank(governor);
        vm.expectRevert(PortageRouter.ZeroAmount.selector);
        router.adoptOrphan(sh, 0);
    }

    function test_adoptedId_cannotLaterBeCredited() public {
        // Governor adopts a direct transfer under an id, then a real deposit with the same id
        // cannot be double-booked: the forwarder's credit reverts and nothing is minted.
        usdc.mint(address(router), 1e6); // direct transfer
        SpecParams memory p = _spec(5e6, keccak256("later"), address(forwarder));
        bytes32 sh = _specHash(p);
        vm.prank(governor);
        router.adoptOrphan(sh, 1e6);

        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        PayoutMeta memory meta = _meta();
        bytes memory metaSig = _signMeta(sh, meta);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(PortageRouter.AlreadyProcessed.selector, sh));
        forwarder.executeMintWithMeta(att, sig, meta, metaSig);
        assertEq(usdc.balanceOf(address(router)), 1e6, "the reverted tx minted nothing");
    }
}
