// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ISettlementCondition} from "./ISettlementCondition.sol";
import {IConditionalEscrow} from "./IConditionalEscrow.sol";

/// @title AttestationCondition
/// @notice Settlement condition (SPEC.md §1) that resolves when a designated attester signs off on
///         an allocation. The payer names the attester once at init; the attester then makes a
///         single, final on-chain attestation of `(recipients, amounts)`. There is no revision —
///         the attester's decision is one-shot.
///
/// @dev One deployment serves every deal of a single `ConditionalEscrow` (immutable `escrow`); the
///      escrow writes nothing here (D5). The attester may be any address (payer, a participant, or
///      an independent third party — no restriction, by design). `recipients ⊆ participants` and
///      `Σ == deal.amount` are validated at attest time as defense-in-depth (consistent with the
///      other conditions); the escrow re-checks both at resolve (I11/I2). Holds no funds.
contract AttestationCondition is ISettlementCondition {
    error NotPayer(bytes32 dealId, address caller);
    error NotAttester(bytes32 dealId, address caller);
    error AlreadyInitialized(bytes32 dealId);
    error NotInitialized(bytes32 dealId);
    error AlreadyAttested(bytes32 dealId);
    error ZeroAddress();
    error DealNotOpen(bytes32 dealId, IConditionalEscrow.State state);
    error EmptyAllocation(bytes32 dealId);
    error AllocationLengthMismatch(uint256 recipients, uint256 amounts);
    error RecipientNotParticipant(bytes32 dealId, address recipient);
    error AllocationSumMismatch(bytes32 dealId, uint256 provided, uint256 expected);

    event Initialized(bytes32 indexed dealId, address indexed attester);
    event Attested(bytes32 indexed dealId, address indexed attester);

    struct Attestation {
        bool initialized;
        bool attested;
        address attester;
        address[] recipients;
        uint256[] amounts;
    }

    /// @notice The escrow this condition serves. Read (never written) for deal identity/params.
    IConditionalEscrow public immutable escrow;

    mapping(bytes32 dealId => Attestation) private _a;

    constructor(address escrow_) {
        escrow = IConditionalEscrow(escrow_);
    }

    /// @notice Payer names the attester for a deal (once).
    /// @dev Order: AlreadyInitialized → deal Funded/Resolving → caller must be the escrow payer →
    ///      non-zero attester.
    function initialize(bytes32 dealId, address attester) external {
        if (_a[dealId].initialized) revert AlreadyInitialized(dealId);
        _requireOpen(dealId);
        if (msg.sender != escrow.payerOf(dealId)) revert NotPayer(dealId, msg.sender);
        if (attester == address(0)) revert ZeroAddress();

        Attestation storage att = _a[dealId];
        att.initialized = true;
        att.attester = attester;

        emit Initialized(dealId, attester);
    }

    /// @notice The designated attester records the final allocation (once). This is the resolution.
    /// @dev Order: NotInitialized → deal Funded/Resolving → caller must be the attester →
    ///      AlreadyAttested → allocation validation (non-empty, equal length, recipients ⊆
    ///      participants, Σ == deal.amount).
    function attest(bytes32 dealId, address[] calldata recipients, uint256[] calldata amounts) external {
        Attestation storage att = _a[dealId];
        if (!att.initialized) revert NotInitialized(dealId);
        _requireOpen(dealId);
        if (msg.sender != att.attester) revert NotAttester(dealId, msg.sender);
        if (att.attested) revert AlreadyAttested(dealId);

        _validateAllocation(dealId, recipients, amounts);

        att.attested = true;
        att.recipients = recipients;
        att.amounts = amounts;

        emit Attested(dealId, msg.sender);
    }

    /// @inheritdoc ISettlementCondition
    /// @dev Settled once the attester has attested; the recorded allocation is fixed (SPEC §3, T8:
    ///      view, no caller-dependent side effects).
    function resolve(bytes32 dealId)
        external
        view
        returns (bool settled, address[] memory recipients, uint256[] memory amounts)
    {
        Attestation storage att = _a[dealId];
        if (!att.attested) {
            return (false, new address[](0), new uint256[](0));
        }
        return (true, att.recipients, att.amounts);
    }

    // --- views ---

    function isInitialized(bytes32 dealId) external view returns (bool) {
        return _a[dealId].initialized;
    }

    function isAttested(bytes32 dealId) external view returns (bool) {
        return _a[dealId].attested;
    }

    function attesterOf(bytes32 dealId) external view returns (address) {
        return _a[dealId].attester;
    }

    // --- internals ---

    /// @dev Deal must be Funded/Resolving (a Resolved/Refunded/Cancelled deal is untouchable).
    function _requireOpen(bytes32 dealId) private view {
        IConditionalEscrow.State state = escrow.stateOf(dealId);
        if (state != IConditionalEscrow.State.Funded && state != IConditionalEscrow.State.Resolving) {
            revert DealNotOpen(dealId, state);
        }
    }

    /// @dev Defense-in-depth validation (the escrow re-checks I11/I2 at resolve). Separate frame
    ///      keeps `attest` under the EVM stack limit.
    function _validateAllocation(bytes32 dealId, address[] calldata recipients, uint256[] calldata amounts)
        private
        view
    {
        uint256 n = recipients.length;
        if (n == 0) revert EmptyAllocation(dealId);
        if (n != amounts.length) revert AllocationLengthMismatch(n, amounts.length);
        address[] memory participants = escrow.participantsOf(dealId);
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            if (!_contains(participants, recipients[i])) revert RecipientNotParticipant(dealId, recipients[i]);
            sum += amounts[i];
        }
        uint256 dealAmount = escrow.dealAmount(dealId);
        if (sum != dealAmount) revert AllocationSumMismatch(dealId, sum, dealAmount);
    }

    function _contains(address[] memory set, address who) private pure returns (bool) {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] == who) return true;
        }
        return false;
    }
}
