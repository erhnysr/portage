// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title ISettlementCondition
/// @notice Pluggable settlement condition for the Portage conditional-settlement layer.
///         Signature is copied verbatim from SPEC.md §3 — do not change it here without
///         updating the SPEC and the escrow together.
///
/// @dev `view` is deliberate (SPEC §3): the escrow must read the outcome without granting
///      the condition an opportunity to reenter or mutate state during resolution.
interface ISettlementCondition {
    /// @notice Report whether this deal's condition is finally resolved.
    /// @dev MUST be free of side effects that depend on the caller.
    ///      MUST return settled=false unless the outcome is final and immutable.
    ///      MUST NOT return an allocation whose recipients are outside the
    ///      participant set the escrow registered at open time.
    /// @return settled      true only if the outcome is final
    /// @return recipients   addresses to be paid
    /// @return amounts      parallel array; MUST sum to the full deal amount
    function resolve(bytes32 dealId)
        external
        view
        returns (bool settled, address[] memory recipients, uint256[] memory amounts);
}
