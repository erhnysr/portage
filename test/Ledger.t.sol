// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ledger} from "../contracts/core/Ledger.sol";
import {AppRegistry} from "../contracts/core/AppRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract LedgerTest is Test {
    Ledger ledger;
    AppRegistry registry;
    MockUSDC usdc;

    address governor = makeAddr("governor");
    address router = makeAddr("router"); // creditor
    address engine = makeAddr("engine"); // debitor
    address appOwner = makeAddr("appOwner");
    address controller = makeAddr("controller");
    address recipient = makeAddr("recipient");
    address stranger = makeAddr("stranger");

    bytes32 constant APP = keccak256("coliseum");
    bytes32 constant APP_B = keccak256("basedrop");
    bytes32 constant ARENA = keccak256("arena-1");

    event Credited(bytes32 indexed appId, bytes32 indexed account, uint256 amount, bytes32 indexed transferId);
    event Debited(bytes32 indexed appId, bytes32 indexed account, uint256 amount, address indexed to);

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AppRegistry(governor);
        ledger = new Ledger(governor, address(usdc), address(registry));

        vm.startPrank(governor);
        ledger.setCreditor(router);
        ledger.setDebitor(engine);
        registry.registerApp(APP, appOwner, controller);
        registry.registerApp(APP_B, appOwner, controller);
        vm.stopPrank();

        // Router holds USDC (as if freshly minted by Gateway) and approves the Ledger to pull.
        usdc.mint(router, 1_000_000e6);
        vm.prank(router);
        usdc.approve(address(ledger), type(uint256).max);
    }

    // ----- construction / wiring -----

    function test_constructor_revertsOnZeroArgs() public {
        // Zero governor is caught by Ownable; zero usdc/registry by the Ledger.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new Ledger(address(0), address(usdc), address(registry));
        vm.expectRevert(Ledger.ZeroAddress.selector);
        new Ledger(governor, address(0), address(registry));
        vm.expectRevert(Ledger.ZeroAddress.selector);
        new Ledger(governor, address(usdc), address(0));
    }

    function test_setCreditorDebitor_onlyGovernor() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        ledger.setCreditor(stranger);
    }

    // ----- credit -----

    function test_credit_happyPath() public {
        vm.expectEmit(true, true, true, true);
        emit Credited(APP, ARENA, 5e6, bytes32("t1"));

        vm.prank(router);
        ledger.credit(APP, ARENA, 5e6, bytes32("t1"));

        assertEq(ledger.balanceOf(APP, ARENA), 5e6);
        assertEq(ledger.appBalance(APP), 5e6);
        assertEq(ledger.custodyTotal(), 5e6);
        assertEq(ledger.totalCredited(APP), 5e6);
        assertEq(usdc.balanceOf(address(ledger)), 5e6);
    }

    function test_credit_onlyCreditor() public {
        vm.expectRevert(abi.encodeWithSelector(Ledger.NotCreditor.selector, stranger));
        vm.prank(stranger);
        ledger.credit(APP, ARENA, 5e6, bytes32("t1"));
    }

    function test_credit_revertsOnZeroAmount() public {
        vm.prank(router);
        vm.expectRevert(Ledger.ZeroAmount.selector);
        ledger.credit(APP, ARENA, 0, bytes32("t1"));
    }

    function test_credit_revertsForUnregisteredApp() public {
        bytes32 ghost = keccak256("ghost");
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(Ledger.AppNotRegistered.selector, ghost));
        ledger.credit(ghost, ARENA, 5e6, bytes32("t1"));
    }

    function test_credit_idempotentOnTransferId() public {
        vm.startPrank(router);
        ledger.credit(APP, ARENA, 5e6, bytes32("t1"));
        vm.expectRevert(abi.encodeWithSelector(Ledger.TransferAlreadyProcessed.selector, bytes32("t1")));
        ledger.credit(APP, ARENA, 5e6, bytes32("t1"));
        vm.stopPrank();
        // only credited once
        assertEq(ledger.custodyTotal(), 5e6);
    }

    // ----- debit -----

    function test_debit_happyPath() public {
        vm.prank(router);
        ledger.credit(APP, ARENA, 10e6, bytes32("t1"));

        vm.expectEmit(true, true, true, true);
        emit Debited(APP, ARENA, 4e6, recipient);

        vm.prank(engine);
        ledger.debit(APP, ARENA, 4e6, recipient);

        assertEq(ledger.balanceOf(APP, ARENA), 6e6);
        assertEq(ledger.appBalance(APP), 6e6);
        assertEq(ledger.custodyTotal(), 6e6);
        assertEq(ledger.totalPaid(APP), 4e6);
        assertEq(usdc.balanceOf(recipient), 4e6);
    }

    function test_debit_onlyDebitor() public {
        vm.prank(router);
        ledger.credit(APP, ARENA, 10e6, bytes32("t1"));

        vm.expectRevert(abi.encodeWithSelector(Ledger.NotDebitor.selector, stranger));
        vm.prank(stranger);
        ledger.debit(APP, ARENA, 4e6, recipient);
    }

    function test_debit_revertsOnInsufficientBalance() public {
        vm.prank(router);
        ledger.credit(APP, ARENA, 3e6, bytes32("t1"));

        vm.prank(engine);
        vm.expectRevert(abi.encodeWithSelector(Ledger.InsufficientAppBalance.selector, APP, ARENA, 4e6, 3e6));
        ledger.debit(APP, ARENA, 4e6, recipient);
    }

    function test_debit_revertsToZeroRecipient() public {
        vm.prank(router);
        ledger.credit(APP, ARENA, 3e6, bytes32("t1"));
        vm.prank(engine);
        vm.expectRevert(Ledger.ZeroAddress.selector);
        ledger.debit(APP, ARENA, 1e6, address(0));
    }

    function test_debit_blockedWhenPaused() public {
        vm.prank(router);
        ledger.credit(APP, ARENA, 10e6, bytes32("t1"));

        vm.prank(appOwner);
        registry.setAppPaused(APP, true);

        vm.prank(engine);
        vm.expectRevert(abi.encodeWithSelector(Ledger.AppPaused.selector, APP));
        ledger.debit(APP, ARENA, 4e6, recipient);
    }

    function test_credit_allowedWhenPaused() public {
        // Pausing halts outflows but incoming consolidation is still accounted.
        vm.prank(appOwner);
        registry.setAppPaused(APP, true);

        vm.prank(router);
        ledger.credit(APP, ARENA, 5e6, bytes32("t1"));
        assertEq(ledger.balanceOf(APP, ARENA), 5e6);
    }

    // ----- app isolation -----

    function test_isolation_debitCannotCrossAppBoundary() public {
        // Fund app A only.
        vm.prank(router);
        ledger.credit(APP, ARENA, 10e6, bytes32("t1"));

        // App B has no balance in the same account key — debit must revert.
        vm.prank(engine);
        vm.expectRevert(abi.encodeWithSelector(Ledger.InsufficientAppBalance.selector, APP_B, ARENA, 1e6, 0));
        ledger.debit(APP_B, ARENA, 1e6, recipient);

        // App A's funds are untouched.
        assertEq(ledger.balanceOf(APP, ARENA), 10e6);
    }

    function test_isolation_totalsTrackPerApp() public {
        vm.startPrank(router);
        ledger.credit(APP, ARENA, 10e6, bytes32("t1"));
        ledger.credit(APP_B, ARENA, 7e6, bytes32("t2"));
        vm.stopPrank();

        assertEq(ledger.appBalance(APP), 10e6);
        assertEq(ledger.appBalance(APP_B), 7e6);
        assertEq(ledger.custodyTotal(), 17e6);
    }

    // ----- core invariant, checked inline over a mixed sequence -----

    function test_invariant_custodyEqualsSumOfApps_inline() public {
        vm.startPrank(router);
        ledger.credit(APP, ARENA, 10e6, bytes32("t1"));
        ledger.credit(APP_B, keccak256("acct2"), 7e6, bytes32("t2"));
        vm.stopPrank();

        vm.prank(engine);
        ledger.debit(APP, ARENA, 3e6, recipient);

        assertEq(ledger.custodyTotal(), ledger.appBalance(APP) + ledger.appBalance(APP_B));
        assertLe(ledger.custodyTotal(), usdc.balanceOf(address(ledger)));
    }
}
