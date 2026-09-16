// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title ConditionRegistry (STUB)
/// @notice Governor-owned allowlist of approved settlement conditions (SPEC.md §2.2 / D3).
///         A deal may only be opened against a condition approved here (I9). The T11 trust
///         assumption lives here, and the v2 timelock on additions is added here rather than
///         to immutable core.
///
/// @dev Failing-first stub (build order §10.4): the constructor records the governor so tests
///      can deploy it, but EVERY function reverts `NotImplemented()`. No allowlist logic yet.
contract ConditionRegistry {
    /// @dev Every stubbed function reverts with this until the real logic lands.
    error NotImplemented();

    /// @notice The Portage governor (expected multisig). Records intent only; not yet enforced.
    address public immutable governor;

    event ConditionApprovalSet(address indexed condition, bool approved);

    constructor(address governor_) {
        governor = governor_;
    }

    /// @notice Approve or revoke a settlement condition. Governor-only (once implemented).
    function setApproved(address, bool) external pure {
        revert NotImplemented();
    }

    /// @notice Whether a condition is currently approved for attachment (I9).
    function isApproved(address) external pure returns (bool) {
        revert NotImplemented();
    }
}
