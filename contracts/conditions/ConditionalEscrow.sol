// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IConditionalEscrow} from "./IConditionalEscrow.sol";

/// @title ConditionalEscrow (STUB)
/// @notice Conditional-settlement escrow over Portage core (SPEC.md §2.1). This is the
///         failing-first stub for build order §10.3: it wires the constructor so tests can
///         deploy against real Portage core, but EVERY function reverts `NotImplemented()`.
///         No business logic is present. The invariant/threat tests written against it are
///         therefore all red until `ConditionalEscrow` is implemented (build order §10.5).
///
/// @dev Custody model (D8): principal lives in `Ledger.balances[appId][dealId]`; this contract
///      is registered as `payoutControllerOf(appId)` and releases funds via
///      `PayoutEngine.payout` (SPEC §2.1). It holds no funds itself.
contract ConditionalEscrow is IConditionalEscrow {
    /// @dev Every stubbed function reverts with this until the real logic lands.
    error NotImplemented();

    /// @notice Portage AppRegistry (immutable core). Read for the D9 controller check.
    address public immutable registry;
    /// @notice Portage Ledger (immutable core). Read for the I18 funding check.
    address public immutable ledger;
    /// @notice Portage PayoutEngine (immutable core). Used to release principal (SPEC §2.1).
    address public immutable payoutEngine;
    /// @notice Condition allowlist (SPEC §2.2). Gates which conditions may be attached (I9).
    address public immutable conditionRegistry;
    /// @notice Portage governor; the only caller allowed to sweep unaccounted surplus (D12).
    address public immutable governor;

    constructor(address registry_, address ledger_, address payoutEngine_, address conditionRegistry_, address governor_) {
        registry = registry_;
        ledger = ledger_;
        payoutEngine = payoutEngine_;
        conditionRegistry = conditionRegistry_;
        governor = governor_;
    }

    // ---------------------------------------------------------------------
    // Lifecycle — all unimplemented
    // ---------------------------------------------------------------------

    function open(bytes32, bytes32, address, bytes32, address, uint256, uint256, address[] calldata)
        external
        pure
        returns (bytes32)
    {
        revert NotImplemented();
    }

    function activate(bytes32) external pure {
        revert NotImplemented();
    }

    function resolve(bytes32) external pure {
        revert NotImplemented();
    }

    function claim(bytes32) external pure {
        revert NotImplemented();
    }

    function refund(bytes32) external pure {
        revert NotImplemented();
    }

    function cancel(bytes32) external pure {
        revert NotImplemented();
    }

    function sweepUnaccounted(bytes32, bytes32, address) external pure {
        revert NotImplemented();
    }

    // ---------------------------------------------------------------------
    // Views — all unimplemented (revert so invariant assertions go red)
    // ---------------------------------------------------------------------

    function stateOf(bytes32) external pure returns (State) {
        revert NotImplemented();
    }

    function appIdOf(bytes32) external pure returns (bytes32) {
        revert NotImplemented();
    }

    function payerOf(bytes32) external pure returns (address) {
        revert NotImplemented();
    }

    function conditionOf(bytes32) external pure returns (address) {
        revert NotImplemented();
    }

    function dealAmount(bytes32) external pure returns (uint256) {
        revert NotImplemented();
    }

    function hardDeadlineOf(bytes32) external pure returns (uint256) {
        revert NotImplemented();
    }

    function participantsOf(bytes32) external pure returns (address[] memory) {
        revert NotImplemented();
    }

    function allocationOf(bytes32) external pure returns (address[] memory, uint256[] memory) {
        revert NotImplemented();
    }

    function claimedOf(bytes32, address) external pure returns (bool) {
        revert NotImplemented();
    }

    function outstanding(bytes32, bytes32) external pure returns (uint256) {
        revert NotImplemented();
    }
}
