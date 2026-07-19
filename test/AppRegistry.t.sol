// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AppRegistry} from "../contracts/core/AppRegistry.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract AppRegistryTest is Test {
    AppRegistry registry;

    address governor = makeAddr("governor");
    address guardian = makeAddr("guardian");
    address appOwner = makeAddr("appOwner");
    address controller = makeAddr("controller");
    address stranger = makeAddr("stranger");

    bytes32 constant APP = keccak256("coliseum");

    event AppRegistered(bytes32 indexed appId, address indexed owner, address indexed payoutController);
    event PayoutControllerUpdated(bytes32 indexed appId, address indexed oldController, address indexed newController);
    event AppPausedSet(bytes32 indexed appId, bool paused, address indexed by);

    function setUp() public {
        registry = new AppRegistry(governor);
        vm.prank(governor);
        registry.setGuardian(guardian);
    }

    // ----- construction -----

    function test_constructor_setsGovernorAsOwner() public view {
        assertEq(registry.owner(), governor);
    }

    function test_constructor_revertsOnZeroGovernor() public {
        // Ownable rejects the zero owner before any custom logic.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AppRegistry(address(0));
    }

    // ----- registerApp -----

    function test_registerApp_byGovernor() public {
        vm.expectEmit(true, true, true, true);
        emit AppRegistered(APP, appOwner, controller);

        vm.prank(governor);
        registry.registerApp(APP, appOwner, controller);

        assertTrue(registry.isRegistered(APP));
        assertFalse(registry.isPaused(APP));
        assertEq(registry.ownerOf(APP), appOwner);
        assertEq(registry.payoutControllerOf(APP), controller);
    }

    function test_registerApp_revertsForNonGovernor() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        registry.registerApp(APP, appOwner, controller);
    }

    function test_registerApp_revertsOnDuplicate() public {
        vm.startPrank(governor);
        registry.registerApp(APP, appOwner, controller);
        vm.expectRevert(abi.encodeWithSelector(AppRegistry.AppAlreadyExists.selector, APP));
        registry.registerApp(APP, appOwner, controller);
        vm.stopPrank();
    }

    function test_registerApp_revertsOnZeroAppId() public {
        vm.prank(governor);
        vm.expectRevert(AppRegistry.ZeroAppId.selector);
        registry.registerApp(bytes32(0), appOwner, controller);
    }

    function test_registerApp_revertsOnZeroAddresses() public {
        vm.startPrank(governor);
        vm.expectRevert(AppRegistry.ZeroAddress.selector);
        registry.registerApp(APP, address(0), controller);
        vm.expectRevert(AppRegistry.ZeroAddress.selector);
        registry.registerApp(APP, appOwner, address(0));
        vm.stopPrank();
    }

    // ----- setPayoutController -----

    function test_setPayoutController_byAppOwner() public {
        _register();
        address newController = makeAddr("newController");

        vm.expectEmit(true, true, true, true);
        emit PayoutControllerUpdated(APP, controller, newController);

        vm.prank(appOwner);
        registry.setPayoutController(APP, newController);
        assertEq(registry.payoutControllerOf(APP), newController);
    }

    function test_setPayoutController_revertsForNonOwner() public {
        _register();
        vm.expectRevert(abi.encodeWithSelector(AppRegistry.NotAppOwner.selector, APP, stranger));
        vm.prank(stranger);
        registry.setPayoutController(APP, stranger);
    }

    function test_setPayoutController_revertsForUnknownApp() public {
        vm.expectRevert(abi.encodeWithSelector(AppRegistry.AppDoesNotExist.selector, APP));
        vm.prank(appOwner);
        registry.setPayoutController(APP, controller);
    }

    // ----- transferAppOwnership -----

    function test_transferAppOwnership() public {
        _register();
        address newOwner = makeAddr("newOwner");
        vm.prank(appOwner);
        registry.transferAppOwnership(APP, newOwner);
        assertEq(registry.ownerOf(APP), newOwner);

        // old owner can no longer act
        vm.expectRevert(abi.encodeWithSelector(AppRegistry.NotAppOwner.selector, APP, appOwner));
        vm.prank(appOwner);
        registry.setPayoutController(APP, controller);
    }

    // ----- pause / unpause -----

    function test_pause_byAppOwner() public {
        _register();
        vm.expectEmit(true, false, true, true);
        emit AppPausedSet(APP, true, appOwner);
        vm.prank(appOwner);
        registry.setAppPaused(APP, true);
        assertTrue(registry.isPaused(APP));
    }

    function test_pause_byGuardian() public {
        _register();
        vm.prank(guardian);
        registry.setAppPaused(APP, true);
        assertTrue(registry.isPaused(APP));
    }

    function test_pause_revertsForStranger() public {
        _register();
        vm.expectRevert(abi.encodeWithSelector(AppRegistry.NotAuthorizedToPause.selector, APP, stranger));
        vm.prank(stranger);
        registry.setAppPaused(APP, true);
    }

    function test_unpause_byOwnerOnly_guardianCannotUnpause() public {
        _register();
        vm.prank(guardian);
        registry.setAppPaused(APP, true);

        // guardian cannot unpause
        vm.expectRevert(abi.encodeWithSelector(AppRegistry.NotAppOwner.selector, APP, guardian));
        vm.prank(guardian);
        registry.setAppPaused(APP, false);

        // owner can
        vm.prank(appOwner);
        registry.setAppPaused(APP, false);
        assertFalse(registry.isPaused(APP));
    }

    // ----- isolation: two apps are independent -----

    function test_isolation_pauseOneAppDoesNotAffectAnother() public {
        bytes32 appB = keccak256("basedrop");
        vm.startPrank(governor);
        registry.registerApp(APP, appOwner, controller);
        registry.registerApp(appB, appOwner, controller);
        vm.stopPrank();

        vm.prank(appOwner);
        registry.setAppPaused(APP, true);

        assertTrue(registry.isPaused(APP));
        assertFalse(registry.isPaused(appB));
    }

    function _register() internal {
        vm.prank(governor);
        registry.registerApp(APP, appOwner, controller);
    }
}
