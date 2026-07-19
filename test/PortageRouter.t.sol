// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortageRouter} from "../contracts/periphery/PortageRouter.sol";
import {Ledger} from "../contracts/core/Ledger.sol";
import {AppRegistry} from "../contracts/core/AppRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {PayoutMeta, PayoutMetaLib, PayoutAction} from "../contracts/lib/PayoutMetaLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Unit tests for PortageRouter.credit, calling as the wired forwarder EOA (the mint side
///         is covered end-to-end in PortageMintForwarder.t.sol).
contract PortageRouterTest is Test {
    PortageRouter router;
    Ledger ledger;
    AppRegistry registry;
    MockUSDC usdc;

    address governor = makeAddr("governor");
    address forwarder = makeAddr("forwarder");
    address appOwner = makeAddr("appOwner");
    address controller = makeAddr("controller");
    address stranger = makeAddr("stranger");
    address payer = makeAddr("payer");
    address refundee = makeAddr("refundee");

    bytes32 constant APP = keccak256("coliseum");
    bytes32 constant ARENA = keccak256("arena-1");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AppRegistry(governor);
        ledger = new Ledger(governor, address(usdc), address(registry));
        router = new PortageRouter(governor, address(usdc), address(ledger), address(registry));

        vm.startPrank(governor);
        ledger.setCreditor(address(router));
        router.setForwarder(forwarder);
        registry.registerApp(APP, appOwner, controller);
        vm.stopPrank();
    }

    function _validMeta(bytes32 appId, bytes32 account) internal view returns (bytes memory) {
        return PayoutMetaLib.encode(
            PayoutMeta({
                schema: 1,
                appId: appId,
                account: account,
                action: PayoutAction.ENTRY_FEE,
                referenceId: keccak256("ref-1"),
                payer: bytes32(uint256(uint160(payer)))
            })
        );
    }

    /// Simulates a mint landing: put USDC on the router, as the GatewayMinter would.
    function _seedMint(uint256 amount) internal {
        usdc.mint(address(router), amount);
    }

    // ----- happy path -----

    function test_credit_forwardsToLedger() public {
        _seedMint(5e6);
        vm.prank(forwarder);
        router.credit(_validMeta(APP, ARENA), 5e6, bytes32("s1"));

        assertEq(ledger.balanceOf(APP, ARENA), 5e6);
        assertEq(usdc.balanceOf(address(ledger)), 5e6);
        assertEq(usdc.balanceOf(address(router)), 0, "router holds no funds at rest");
        assertEq(router.quarantinedTotal(), 0);
        assertTrue(router.processed(bytes32("s1")));
    }

    function test_credit_allowedWhenAppPaused() public {
        vm.prank(appOwner);
        registry.setAppPaused(APP, true);

        _seedMint(5e6);
        vm.prank(forwarder);
        router.credit(_validMeta(APP, ARENA), 5e6, bytes32("s1"));
        assertEq(ledger.balanceOf(APP, ARENA), 5e6); // credit not blocked by pause
    }

    function test_credit_onlyForwarder() public {
        _seedMint(5e6);
        vm.expectRevert(abi.encodeWithSelector(PortageRouter.NotForwarder.selector, stranger));
        vm.prank(stranger);
        router.credit(_validMeta(APP, ARENA), 5e6, bytes32("s1"));
    }

    function test_credit_idempotentOnSpecHash() public {
        _seedMint(10e6);
        vm.startPrank(forwarder);
        router.credit(_validMeta(APP, ARENA), 5e6, bytes32("s1"));
        vm.expectRevert(abi.encodeWithSelector(PortageRouter.AlreadyProcessed.selector, bytes32("s1")));
        router.credit(_validMeta(APP, ARENA), 5e6, bytes32("s1"));
        vm.stopPrank();
    }

    // ----- quarantine: malformed hookData -----

    function test_credit_malformedHookData_quarantines() public {
        _seedMint(5e6);
        bytes memory garbage = hex"deadbeef";

        vm.expectEmit(true, false, false, true);
        emit PortageRouter.Quarantined(bytes32("s1"), 5e6, PortageRouter.QuarantineReason.MalformedHookData);

        vm.prank(forwarder);
        router.credit(garbage, 5e6, bytes32("s1"));

        assertEq(router.quarantined(bytes32("s1")), 5e6);
        assertEq(router.quarantinedTotal(), 5e6);
        assertEq(usdc.balanceOf(address(router)), 5e6, "quarantined funds held on router");
        assertEq(ledger.balanceOf(APP, ARENA), 0, "never credited to any app");
    }

    function test_credit_wrongSchema_quarantines() public {
        _seedMint(5e6);
        // Correct length but schema = 2 (unknown).
        bytes memory badSchema = abi.encode(uint8(2), APP, ARENA, uint8(0), bytes32(0), bytes32(0));
        vm.prank(forwarder);
        router.credit(badSchema, 5e6, bytes32("s1"));
        assertEq(router.quarantined(bytes32("s1")), 5e6);
        assertEq(ledger.balanceOf(APP, ARENA), 0);
    }

    // ----- quarantine: unregistered app -----

    function test_credit_unregisteredApp_quarantines() public {
        _seedMint(5e6);
        bytes32 ghost = keccak256("ghost-app");

        vm.expectEmit(true, false, false, true);
        emit PortageRouter.Quarantined(bytes32("s1"), 5e6, PortageRouter.QuarantineReason.UnregisteredApp);

        vm.prank(forwarder);
        router.credit(_validMeta(ghost, ARENA), 5e6, bytes32("s1"));

        assertEq(router.quarantined(bytes32("s1")), 5e6);
        assertEq(ledger.appBalance(ghost), 0);
    }

    // ----- quarantine resolution -----

    function test_resolveQuarantineToApp() public {
        _seedMint(5e6);
        bytes32 ghost = keccak256("ghost-app");
        vm.prank(forwarder);
        router.credit(_validMeta(ghost, ARENA), 5e6, bytes32("s1"));

        // Governor reattributes to the correct, registered app.
        vm.prank(governor);
        router.resolveQuarantineToApp(bytes32("s1"), APP, ARENA);

        assertEq(router.quarantined(bytes32("s1")), 0);
        assertEq(router.quarantinedTotal(), 0);
        assertEq(ledger.balanceOf(APP, ARENA), 5e6);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_resolveQuarantine_onlyGovernor() public {
        _seedMint(5e6);
        vm.prank(forwarder);
        router.credit(hex"deadbeef", 5e6, bytes32("s1"));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.resolveQuarantineToApp(bytes32("s1"), APP, ARENA);
    }

    function test_resolveQuarantine_revertsForUnregisteredTarget() public {
        _seedMint(5e6);
        vm.prank(forwarder);
        router.credit(hex"deadbeef", 5e6, bytes32("s1"));

        bytes32 ghost = keccak256("ghost-app");
        vm.expectRevert(abi.encodeWithSelector(PortageRouter.AppNotRegistered.selector, ghost));
        vm.prank(governor);
        router.resolveQuarantineToApp(bytes32("s1"), ghost, ARENA);
    }

    function test_resolveQuarantine_revertsWhenNothing() public {
        vm.expectRevert(abi.encodeWithSelector(PortageRouter.NothingQuarantined.selector, bytes32("nope")));
        vm.prank(governor);
        router.resolveQuarantineToApp(bytes32("nope"), APP, ARENA);
    }

    function test_withdrawQuarantine() public {
        _seedMint(5e6);
        vm.prank(forwarder);
        router.credit(hex"deadbeef", 5e6, bytes32("s1"));

        vm.prank(governor);
        router.withdrawQuarantine(bytes32("s1"), refundee);

        assertEq(usdc.balanceOf(refundee), 5e6);
        assertEq(router.quarantined(bytes32("s1")), 0);
        assertEq(router.quarantinedTotal(), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // ----- wiring -----

    function test_setForwarder_onlyGovernor() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        router.setForwarder(stranger);
    }
}
