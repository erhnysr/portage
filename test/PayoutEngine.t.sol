// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutEngine} from "../contracts/core/PayoutEngine.sol";
import {Ledger} from "../contracts/core/Ledger.sol";
import {AppRegistry} from "../contracts/core/AppRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

contract PayoutEngineTest is Test {
    PayoutEngine engine;
    Ledger ledger;
    AppRegistry registry;
    MockUSDC usdc;

    address governor = makeAddr("governor");
    address router = makeAddr("router"); // creditor
    address appOwner = makeAddr("appOwner");
    address controller = makeAddr("controller");
    address controllerB = makeAddr("controllerB");
    address stranger = makeAddr("stranger");
    address w1 = makeAddr("winner1");
    address w2 = makeAddr("winner2");
    address w3 = makeAddr("winner3");

    bytes32 constant APP = keccak256("coliseum");
    bytes32 constant APP_B = keccak256("basedrop");
    bytes32 constant ARENA = keccak256("arena-1");
    bytes32 constant REF = keccak256("round-1");

    event PaidOut(
        bytes32 indexed appId, bytes32 indexed account, bytes32 indexed referenceId, address recipient, uint256 amount
    );
    event Distributed(
        bytes32 indexed appId, bytes32 indexed account, bytes32 indexed referenceId, uint256 totalAmount, uint256 count
    );

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AppRegistry(governor);
        ledger = new Ledger(governor, address(usdc), address(registry));
        engine = new PayoutEngine(address(registry), address(ledger));

        vm.startPrank(governor);
        ledger.setCreditor(router);
        ledger.setDebitor(address(engine));
        registry.registerApp(APP, appOwner, controller);
        registry.registerApp(APP_B, appOwner, controllerB);
        vm.stopPrank();

        usdc.mint(router, 1_000_000e6);
        vm.prank(router);
        usdc.approve(address(ledger), type(uint256).max);
    }

    function _fund(bytes32 appId, bytes32 account, uint256 amount, bytes32 transferId) internal {
        vm.prank(router);
        ledger.credit(appId, account, amount, transferId);
    }

    // ----- payout -----

    function test_payout_happyPath() public {
        _fund(APP, ARENA, 10e6, bytes32("t1"));

        vm.expectEmit(true, true, true, true);
        emit PaidOut(APP, ARENA, REF, w1, 4e6);

        vm.prank(controller);
        engine.payout(APP, ARENA, REF, w1, 4e6);

        assertEq(usdc.balanceOf(w1), 4e6);
        assertEq(ledger.balanceOf(APP, ARENA), 6e6);
        assertEq(ledger.totalPaid(APP), 4e6);
        assertTrue(engine.settled(APP, REF));
    }

    function test_payout_onlyPayoutController() public {
        _fund(APP, ARENA, 10e6, bytes32("t1"));
        vm.expectRevert(abi.encodeWithSelector(PayoutEngine.NotPayoutController.selector, APP, stranger));
        vm.prank(stranger);
        engine.payout(APP, ARENA, REF, w1, 4e6);
    }

    function test_payout_revertsForUnregisteredApp() public {
        bytes32 ghost = keccak256("ghost");
        vm.expectRevert(abi.encodeWithSelector(PayoutEngine.AppNotRegistered.selector, ghost));
        vm.prank(controller);
        engine.payout(ghost, ARENA, REF, w1, 1e6);
    }

    function test_payout_replayProtected() public {
        _fund(APP, ARENA, 10e6, bytes32("t1"));

        vm.startPrank(controller);
        engine.payout(APP, ARENA, REF, w1, 4e6);
        vm.expectRevert(abi.encodeWithSelector(PayoutEngine.AlreadySettled.selector, APP, REF));
        engine.payout(APP, ARENA, REF, w1, 1e6);
        vm.stopPrank();

        // Only paid once.
        assertEq(usdc.balanceOf(w1), 4e6);
        assertEq(ledger.balanceOf(APP, ARENA), 6e6);
    }

    function test_payout_blockedWhenPaused() public {
        _fund(APP, ARENA, 10e6, bytes32("t1"));
        vm.prank(appOwner);
        registry.setAppPaused(APP, true);

        vm.expectRevert(abi.encodeWithSelector(Ledger.AppPaused.selector, APP));
        vm.prank(controller);
        engine.payout(APP, ARENA, REF, w1, 4e6);

        // referenceId must NOT be consumed by a reverted payout.
        assertFalse(engine.settled(APP, REF));
    }

    function test_payout_revertsOnInsufficientBalance() public {
        _fund(APP, ARENA, 3e6, bytes32("t1"));
        vm.expectRevert(abi.encodeWithSelector(Ledger.InsufficientAppBalance.selector, APP, ARENA, 4e6, 3e6));
        vm.prank(controller);
        engine.payout(APP, ARENA, REF, w1, 4e6);
        assertFalse(engine.settled(APP, REF));
    }

    // ----- distribute -----

    function test_distribute_happyPath() public {
        _fund(APP, ARENA, 20e6, bytes32("t1"));

        address[] memory to = new address[](3);
        to[0] = w1;
        to[1] = w2;
        to[2] = w3;
        uint256[] memory amt = new uint256[](3);
        amt[0] = 5e6;
        amt[1] = 7e6;
        amt[2] = 3e6;

        vm.expectEmit(true, true, true, true);
        emit Distributed(APP, ARENA, REF, 15e6, 3);

        vm.prank(controller);
        engine.distribute(APP, ARENA, REF, to, amt);

        assertEq(usdc.balanceOf(w1), 5e6);
        assertEq(usdc.balanceOf(w2), 7e6);
        assertEq(usdc.balanceOf(w3), 3e6);
        assertEq(ledger.balanceOf(APP, ARENA), 5e6);
        assertEq(ledger.totalPaid(APP), 15e6);
        assertTrue(engine.settled(APP, REF));
    }

    function test_distribute_revertsOnLengthMismatch() public {
        _fund(APP, ARENA, 20e6, bytes32("t1"));
        address[] memory to = new address[](2);
        to[0] = w1;
        to[1] = w2;
        uint256[] memory amt = new uint256[](1);
        amt[0] = 5e6;

        vm.expectRevert(abi.encodeWithSelector(PayoutEngine.LengthMismatch.selector, 2, 1));
        vm.prank(controller);
        engine.distribute(APP, ARENA, REF, to, amt);
    }

    function test_distribute_revertsOnEmptyBatch() public {
        address[] memory to = new address[](0);
        uint256[] memory amt = new uint256[](0);
        vm.expectRevert(PayoutEngine.EmptyBatch.selector);
        vm.prank(controller);
        engine.distribute(APP, ARENA, REF, to, amt);
    }

    function test_distribute_atomic_revertsWhenTotalExceedsBalance() public {
        _fund(APP, ARENA, 10e6, bytes32("t1"));

        address[] memory to = new address[](2);
        to[0] = w1;
        to[1] = w2;
        uint256[] memory amt = new uint256[](2);
        amt[0] = 6e6;
        amt[1] = 5e6; // total 11 > 10 -> second debit reverts

        vm.expectRevert(abi.encodeWithSelector(Ledger.InsufficientAppBalance.selector, APP, ARENA, 5e6, 4e6));
        vm.prank(controller);
        engine.distribute(APP, ARENA, REF, to, amt);

        // Whole batch rolled back: no partial payment, referenceId unsettled.
        assertEq(usdc.balanceOf(w1), 0);
        assertEq(usdc.balanceOf(w2), 0);
        assertEq(ledger.balanceOf(APP, ARENA), 10e6);
        assertFalse(engine.settled(APP, REF));
    }

    function test_distribute_replayProtected() public {
        _fund(APP, ARENA, 20e6, bytes32("t1"));
        address[] memory to = new address[](1);
        to[0] = w1;
        uint256[] memory amt = new uint256[](1);
        amt[0] = 5e6;

        vm.startPrank(controller);
        engine.distribute(APP, ARENA, REF, to, amt);
        vm.expectRevert(abi.encodeWithSelector(PayoutEngine.AlreadySettled.selector, APP, REF));
        engine.distribute(APP, ARENA, REF, to, amt);
        vm.stopPrank();
    }

    // ----- app isolation -----

    function test_isolation_controllerCannotPayoutAnotherApp() public {
        _fund(APP, ARENA, 10e6, bytes32("t1")); // fund app A
        _fund(APP_B, ARENA, 10e6, bytes32("t2")); // fund app B

        // App A's controller cannot pay out from App B.
        vm.expectRevert(abi.encodeWithSelector(PayoutEngine.NotPayoutController.selector, APP_B, controller));
        vm.prank(controller);
        engine.payout(APP_B, ARENA, REF, w1, 1e6);

        // App B untouched.
        assertEq(ledger.balanceOf(APP_B, ARENA), 10e6);
    }

    function test_isolation_sameReferenceIdIndependentAcrossApps() public {
        _fund(APP, ARENA, 10e6, bytes32("t1"));
        _fund(APP_B, ARENA, 10e6, bytes32("t2"));

        vm.prank(controller);
        engine.payout(APP, ARENA, REF, w1, 4e6);

        // Same REF value is a distinct key for a different app; must succeed.
        vm.prank(controllerB);
        engine.payout(APP_B, ARENA, REF, w2, 3e6);

        assertTrue(engine.settled(APP, REF));
        assertTrue(engine.settled(APP_B, REF));
        assertEq(usdc.balanceOf(w1), 4e6);
        assertEq(usdc.balanceOf(w2), 3e6);
    }
}
