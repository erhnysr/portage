// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title AppRegistry
/// @notice Identity and access-control registry for applications integrated with Portage.
///         Every integrated app has a unique `appId`, an `owner` (can rotate its controller
///         and pause the app), and a `payoutController` (the only key allowed to trigger
///         payouts for that app in the PayoutEngine).
///
/// @dev This contract is part of the immutable PortageCore. It holds NO funds and performs
///      NO value transfers — it is pure identity/access state that the Ledger and (later)
///      the PayoutEngine read to enforce app isolation. The `owner()` of this contract is
///      the Portage governor (expected to be a multisig).
contract AppRegistry is Ownable2Step {
    /// @param exists           Whether this appId has been registered.
    /// @param paused           App-level circuit breaker. Isolated: pausing one app never
    ///                         affects another. When paused, outflows (payouts) are halted.
    /// @param owner            App owner: may rotate the payoutController and pause/unpause.
    /// @param payoutController The only address authorized to initiate payouts for this app.
    struct AppConfig {
        bool exists;
        bool paused;
        address owner;
        address payoutController;
    }

    /// @notice appId => configuration.
    mapping(bytes32 appId => AppConfig config) private _apps;

    /// @notice Guardian may pause (but not unpause) any app as an emergency circuit breaker.
    ///         It can never move funds nor unpause — unpausing is the app owner's decision.
    address public guardian;

    event AppRegistered(bytes32 indexed appId, address indexed owner, address indexed payoutController);
    event PayoutControllerUpdated(bytes32 indexed appId, address indexed oldController, address indexed newController);
    event AppOwnerUpdated(bytes32 indexed appId, address indexed oldOwner, address indexed newOwner);
    event AppPausedSet(bytes32 indexed appId, bool paused, address indexed by);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);

    error ZeroAddress();
    error ZeroAppId();
    error AppAlreadyExists(bytes32 appId);
    error AppDoesNotExist(bytes32 appId);
    error NotAppOwner(bytes32 appId, address caller);
    error NotAuthorizedToPause(bytes32 appId, address caller);

    constructor(address governor_) Ownable(governor_) {}

    // ---------------------------------------------------------------------
    // Governor actions
    // ---------------------------------------------------------------------

    /// @notice Register a new application. Only the governor may onboard apps.
    function registerApp(bytes32 appId, address owner_, address payoutController_) external onlyOwner {
        if (appId == bytes32(0)) revert ZeroAppId();
        if (owner_ == address(0) || payoutController_ == address(0)) revert ZeroAddress();
        if (_apps[appId].exists) revert AppAlreadyExists(appId);

        _apps[appId] = AppConfig({exists: true, paused: false, owner: owner_, payoutController: payoutController_});

        emit AppRegistered(appId, owner_, payoutController_);
    }

    /// @notice Set the guardian address (emergency pauser). Governor only.
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    // ---------------------------------------------------------------------
    // App-owner actions
    // ---------------------------------------------------------------------

    /// @notice Rotate the payout controller for an app. Only the app owner.
    function setPayoutController(bytes32 appId, address newController) external {
        AppConfig storage app = _requireApp(appId);
        if (msg.sender != app.owner) revert NotAppOwner(appId, msg.sender);
        if (newController == address(0)) revert ZeroAddress();

        emit PayoutControllerUpdated(appId, app.payoutController, newController);
        app.payoutController = newController;
    }

    /// @notice Transfer app ownership to a new owner. Only the current app owner.
    function transferAppOwnership(bytes32 appId, address newOwner) external {
        AppConfig storage app = _requireApp(appId);
        if (msg.sender != app.owner) revert NotAppOwner(appId, msg.sender);
        if (newOwner == address(0)) revert ZeroAddress();

        emit AppOwnerUpdated(appId, app.owner, newOwner);
        app.owner = newOwner;
    }

    /// @notice Pause or unpause an app.
    ///         - Pausing: app owner OR guardian (emergency).
    ///         - Unpausing: app owner only.
    function setAppPaused(bytes32 appId, bool paused) external {
        AppConfig storage app = _requireApp(appId);

        if (paused) {
            if (msg.sender != app.owner && msg.sender != guardian) revert NotAuthorizedToPause(appId, msg.sender);
        } else {
            if (msg.sender != app.owner) revert NotAppOwner(appId, msg.sender);
        }

        app.paused = paused;
        emit AppPausedSet(appId, paused, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function appConfig(bytes32 appId) external view returns (AppConfig memory) {
        return _apps[appId];
    }

    function isRegistered(bytes32 appId) external view returns (bool) {
        return _apps[appId].exists;
    }

    function isPaused(bytes32 appId) external view returns (bool) {
        return _apps[appId].paused;
    }

    function ownerOf(bytes32 appId) external view returns (address) {
        return _apps[appId].owner;
    }

    function payoutControllerOf(bytes32 appId) external view returns (address) {
        return _apps[appId].payoutController;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _requireApp(bytes32 appId) private view returns (AppConfig storage app) {
        app = _apps[appId];
        if (!app.exists) revert AppDoesNotExist(appId);
    }
}
