// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ConditionRegistry
/// @notice Governor-owned allowlist of approved settlement conditions (SPEC.md §2.2 / D3).
///         A deal may only be opened against a condition approved here (I9). The T11 trust
///         assumption lives here (an approved-but-malicious condition is accepted for v1); a
///         timelock on additions is the v2 mitigation, added here rather than to immutable core.
///
/// @dev Ownership follows the Portage core pattern verbatim (`AppRegistry.sol:17,50`):
///      `Ownable2Step` with the governor set at construction. `owner()` is the governor.
///      Approval changes are `onlyOwner` and idempotent — re-approving an approved condition or
///      revoking an unapproved one is a no-op (no state change, no event), never a revert.
contract ConditionRegistry is Ownable2Step {
    /// @notice Reverts an attempt to approve the zero address as a condition.
    error ZeroAddress();

    /// @notice Emitted when a condition transitions from unapproved to approved.
    event ConditionApproved(address indexed condition);
    /// @notice Emitted when a condition transitions from approved to unapproved.
    event ConditionRevoked(address indexed condition);

    /// @notice Whether a condition is currently approved for attachment (I9).
    mapping(address condition => bool) public isApproved;

    constructor(address governor_) Ownable(governor_) {}

    /// @notice Approve (`approved == true`) or revoke (`approved == false`) a settlement
    ///         condition. Governor-only (D3). Idempotent: a call that does not change the current
    ///         approval state is a silent no-op. Approving `address(0)` reverts.
    /// @param condition the condition contract whose approval to set.
    /// @param approved  the desired approval state.
    function setApproved(address condition, bool approved) external onlyOwner {
        if (approved && condition == address(0)) revert ZeroAddress();
        if (isApproved[condition] == approved) return; // idempotent no-op

        isApproved[condition] = approved;
        if (approved) {
            emit ConditionApproved(condition);
        } else {
            emit ConditionRevoked(condition);
        }
    }
}
