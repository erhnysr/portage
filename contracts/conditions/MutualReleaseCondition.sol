// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ISettlementCondition} from "./ISettlementCondition.sol";
import {IConditionalEscrow} from "./IConditionalEscrow.sol";

/// @title MutualReleaseCondition
/// @notice Settlement condition (SPEC.md §1) that resolves when ALL parties to a deal sign off on
///         an identical allocation. The party set is the payer plus every registered participant
///         (the same unanimous quorum as `ConditionalEscrow.cancel()`), derived by reading the
///         escrow's public views — the escrow writes nothing here (D5), so this condition inherits
///         the escrow's already-authenticated identities rather than keeping its own party registry.
///
/// @dev One deployment serves every deal of a single `ConditionalEscrow` (immutable `escrow`).
///      A party calls `approve(dealId, recipients, amounts)` with the full proposed allocation;
///      approvals tally per allocation hash (count-per-hash), so a party may float alternatives and
///      the first hash reaching unanimity finalizes (grief-resistant renegotiation). `resolve()` is
///      a pure read of the finalized snapshot.
///
///      Threat notes: recipients ⊆ participants and Σ == deal.amount are validated here as
///      defense-in-depth (SPEC §3), and the escrow re-checks both at resolve (I11/I2) — so a
///      malicious/foreign recipient (T1) is double-gated. resolve() is view and returns the fixed
///      finalized allocation regardless of caller/order (T8). This contract holds no funds.
contract MutualReleaseCondition is ISettlementCondition {
    error NotDealParty(bytes32 dealId, address caller);
    error DealNotOpen(bytes32 dealId, IConditionalEscrow.State state);
    error AlreadyFinalized(bytes32 dealId);
    error EmptyAllocation(bytes32 dealId);
    error AllocationLengthMismatch(uint256 recipients, uint256 amounts);
    error RecipientNotParticipant(bytes32 dealId, address recipient);
    error AllocationSumMismatch(bytes32 dealId, uint256 provided, uint256 expected);

    event AllocationApproved(bytes32 indexed dealId, address indexed party, bytes32 indexed allocationHash);
    event AllocationFinalized(bytes32 indexed dealId, bytes32 allocationHash);

    /// @notice The escrow this condition serves. Read (never written) for deal identity/params.
    IConditionalEscrow public immutable escrow;

    mapping(bytes32 dealId => bool) public finalized;
    mapping(bytes32 dealId => address[]) private _finalRecipients;
    mapping(bytes32 dealId => uint256[]) private _finalAmounts;

    /// @dev dealId => allocationHash => number of distinct parties that approved that allocation.
    mapping(bytes32 dealId => mapping(bytes32 allocationHash => uint256)) public approvalCount;
    /// @dev dealId => allocationHash => party => approved (idempotency; no double counting).
    mapping(bytes32 dealId => mapping(bytes32 allocationHash => mapping(address => bool))) public approved;

    constructor(address escrow_) {
        escrow = IConditionalEscrow(escrow_);
    }

    /// @notice Sign off on `(recipients, amounts)` for `dealId`. When every party (payer + all
    ///         participants, de-duplicated) has approved the SAME allocation, it is finalized.
    /// @dev Order: AlreadyFinalized (locked once unanimous) → DealNotOpen (deal must be
    ///      Funded/Resolving) → NotDealParty (caller must be payer or a participant) → allocation
    ///      validation (non-empty, equal-length, recipients ⊆ participants, Σ == deal.amount).
    function approve(bytes32 dealId, address[] calldata recipients, uint256[] calldata amounts) external {
        if (finalized[dealId]) revert AlreadyFinalized(dealId);
        _requireOpen(dealId);

        // Split across helpers (separate stack frames) to stay under the EVM stack limit.
        address[] memory participants = escrow.participantsOf(dealId);
        uint256 required = _authorizeAndRequired(dealId, participants);
        _validateAllocation(dealId, participants, recipients, amounts);

        bytes32 allocationHash = keccak256(abi.encode(recipients, amounts));

        // Count-per-hash (E): each party approves at most once per allocation; distinct hashes
        // tally independently, so a floated alternative never resets an existing near-consensus.
        if (!approved[dealId][allocationHash][msg.sender]) {
            approved[dealId][allocationHash][msg.sender] = true;
            approvalCount[dealId][allocationHash] += 1;
            emit AllocationApproved(dealId, msg.sender, allocationHash);
        }

        if (approvalCount[dealId][allocationHash] == required) {
            finalized[dealId] = true;
            _finalRecipients[dealId] = recipients;
            _finalAmounts[dealId] = amounts;
            emit AllocationFinalized(dealId, allocationHash);
        }
    }

    /// @dev Deal must be Funded/Resolving (approvals only make sense pre-resolution).
    function _requireOpen(bytes32 dealId) private view {
        IConditionalEscrow.State state = escrow.stateOf(dealId);
        if (state != IConditionalEscrow.State.Funded && state != IConditionalEscrow.State.Resolving) {
            revert DealNotOpen(dealId, state);
        }
    }

    /// @dev Authentication (C): caller must be the payer or a participant. Returns the unanimity
    ///      threshold = payer + participants, de-duplicated if the payer is also a participant.
    function _authorizeAndRequired(bytes32 dealId, address[] memory participants)
        private
        view
        returns (uint256 required)
    {
        address payer = escrow.payerOf(dealId);
        if (msg.sender != payer && !_contains(participants, msg.sender)) revert NotDealParty(dealId, msg.sender);
        required = participants.length + (_contains(participants, payer) ? 0 : 1);
    }

    /// @dev Allocation validation (D — defense-in-depth; the escrow re-checks I11/I2 at resolve).
    function _validateAllocation(
        bytes32 dealId,
        address[] memory participants,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) private view {
        uint256 n = recipients.length;
        if (n == 0) revert EmptyAllocation(dealId);
        if (n != amounts.length) revert AllocationLengthMismatch(n, amounts.length);
        uint256 sum;
        for (uint256 i = 0; i < n; i++) {
            if (!_contains(participants, recipients[i])) revert RecipientNotParticipant(dealId, recipients[i]);
            sum += amounts[i];
        }
        uint256 dealAmount = escrow.dealAmount(dealId);
        if (sum != dealAmount) revert AllocationSumMismatch(dealId, sum, dealAmount);
    }

    /// @inheritdoc ISettlementCondition
    /// @dev Pure read of the finalized snapshot (D5): (false, [], []) until unanimity, then the
    ///      fixed allocation forever. No caller-dependent side effects (SPEC §3).
    function resolve(bytes32 dealId)
        external
        view
        returns (bool settled, address[] memory recipients, uint256[] memory amounts)
    {
        if (!finalized[dealId]) {
            return (false, new address[](0), new uint256[](0));
        }
        return (true, _finalRecipients[dealId], _finalAmounts[dealId]);
    }

    function _contains(address[] memory set, address who) private pure returns (bool) {
        for (uint256 i = 0; i < set.length; i++) {
            if (set[i] == who) return true;
        }
        return false;
    }
}
