// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ISettlementCondition} from "./ISettlementCondition.sol";
import {IConditionalEscrow} from "./IConditionalEscrow.sol";

/// @title TimelockCondition
/// @notice Settlement condition (SPEC.md §1) that resolves when a soft deadline passes with no
///         objection. The payer initializes a proposed allocation and a `softDeadline` strictly
///         before the escrow's `hardDeadline`; if the payer does not object before `softDeadline`,
///         the allocation becomes claimable. An objection is permanent and drops the deal to the
///         escrow's hard-deadline refund path (D4/I7) — the condition never resolves after it.
///
/// @dev One deployment serves every deal of a single `ConditionalEscrow` (immutable `escrow`); the
///      escrow writes nothing here (D5). Identity/params are read from the escrow's public views,
///      so the payer is the escrow-authenticated payer. `recipients ⊆ participants` and
///      `Σ == deal.amount` are validated at init as defense-in-depth (consistent with
///      MutualReleaseCondition); the escrow re-checks both at resolve (I11/I2). Holds no funds.
contract TimelockCondition is ISettlementCondition {
    error NotPayer(bytes32 dealId, address caller);
    error AlreadyInitialized(bytes32 dealId);
    error NotInitialized(bytes32 dealId);
    error AlreadyObjected(bytes32 dealId);
    error ObjectionWindowClosed(bytes32 dealId, uint256 nowTs, uint64 softDeadline);
    error DealNotOpen(bytes32 dealId, IConditionalEscrow.State state);
    error SoftDeadlineNotBeforeHard(uint64 softDeadline, uint256 hardDeadline);
    error EmptyAllocation(bytes32 dealId);
    error AllocationLengthMismatch(uint256 recipients, uint256 amounts);
    error RecipientNotParticipant(bytes32 dealId, address recipient);
    error AllocationSumMismatch(bytes32 dealId, uint256 provided, uint256 expected);

    event Initialized(bytes32 indexed dealId, address indexed payer, uint64 softDeadline);
    event Objected(bytes32 indexed dealId);

    struct Timelock {
        bool initialized;
        bool objected;
        uint64 softDeadline;
        address[] recipients;
        uint256[] amounts;
    }

    /// @notice The escrow this condition serves. Read (never written) for deal identity/params.
    IConditionalEscrow public immutable escrow;

    mapping(bytes32 dealId => Timelock) private _t;

    constructor(address escrow_) {
        escrow = IConditionalEscrow(escrow_);
    }

    /// @notice Payer proposes the timeout allocation and a soft deadline (once per deal). The
    ///         allocation becomes claimable at `softDeadline` unless the payer objects first.
    /// @dev Order: AlreadyInitialized → deal must be Funded/Resolving → caller must be the payer →
    ///      softDeadline strictly before the escrow hardDeadline → allocation validation.
    function initialize(bytes32 dealId, uint64 softDeadline, address[] calldata recipients, uint256[] calldata amounts)
        external
    {
        if (_t[dealId].initialized) revert AlreadyInitialized(dealId);
        _requireOpen(dealId);
        if (msg.sender != escrow.payerOf(dealId)) revert NotPayer(dealId, msg.sender);

        uint256 hardDeadline = escrow.hardDeadlineOf(dealId);
        // The timeout must be able to fire before the escrow's refund path opens.
        if (uint256(softDeadline) >= hardDeadline) revert SoftDeadlineNotBeforeHard(softDeadline, hardDeadline);

        _validateAllocation(dealId, recipients, amounts);

        Timelock storage t = _t[dealId];
        t.initialized = true;
        t.softDeadline = softDeadline;
        t.recipients = recipients;
        t.amounts = amounts;

        emit Initialized(dealId, msg.sender, softDeadline);
    }

    /// @notice Payer permanently blocks the timeout release. Callable only before `softDeadline`,
    ///         once, on an initialized and still-open deal. After this the condition never resolves
    ///         and the deal can only exit via the escrow's hard-deadline refund.
    function object(bytes32 dealId) external {
        Timelock storage t = _t[dealId];
        if (!t.initialized) revert NotInitialized(dealId);
        _requireOpen(dealId);
        if (msg.sender != escrow.payerOf(dealId)) revert NotPayer(dealId, msg.sender);
        if (t.objected) revert AlreadyObjected(dealId);
        if (block.timestamp >= t.softDeadline) revert ObjectionWindowClosed(dealId, block.timestamp, t.softDeadline);

        t.objected = true;
        emit Objected(dealId);
    }

    /// @inheritdoc ISettlementCondition
    /// @dev Settled only once initialized, not objected, and `softDeadline` reached. An objection
    ///      is terminal — resolve() returns settled=false forever after it (SPEC §3, T8: view, no
    ///      caller-dependent side effects).
    function resolve(bytes32 dealId)
        external
        view
        returns (bool settled, address[] memory recipients, uint256[] memory amounts)
    {
        Timelock storage t = _t[dealId];
        if (!t.initialized || t.objected || block.timestamp < t.softDeadline) {
            return (false, new address[](0), new uint256[](0));
        }
        return (true, t.recipients, t.amounts);
    }

    // --- views ---

    function isInitialized(bytes32 dealId) external view returns (bool) {
        return _t[dealId].initialized;
    }

    function isObjected(bytes32 dealId) external view returns (bool) {
        return _t[dealId].objected;
    }

    function softDeadlineOf(bytes32 dealId) external view returns (uint64) {
        return _t[dealId].softDeadline;
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
    ///      keeps `initialize` under the EVM stack limit.
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
