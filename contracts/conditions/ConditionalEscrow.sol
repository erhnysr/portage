// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IConditionalEscrow} from "./IConditionalEscrow.sol";
import {ISettlementCondition} from "./ISettlementCondition.sol";
import {AppRegistry} from "../core/AppRegistry.sol";
import {Ledger} from "../core/Ledger.sol";
import {PayoutEngine} from "../core/PayoutEngine.sol";
import {ConditionRegistry} from "./ConditionRegistry.sol";

/// @title ConditionalEscrow
/// @notice Conditional-settlement escrow layered on immutable Portage core (SPEC.md §2). A payer
///         binds Gateway-deposited USDC to a pluggable {ISettlementCondition}; funds release only
///         when the condition resolves into a concrete, participant-only allocation, and are
///         claimed pull-style per recipient. If the condition never resolves, the payer refunds
///         unilaterally after the hard deadline.
///
/// @dev Custody model (D8): principal lives in `Ledger.balances[appId][dealId]`; this contract is
///      the app's `payoutController` and moves funds only via `PayoutEngine.payout`. It holds no
///      USDC itself. Core is untouched (D7) — attachment is a registry configuration.
///
///      Funding path (§2.1b): the escrow receives no callback when a deposit lands; `open()`
///      verifies funding by reading the Ledger balance. In production the Ledger's sole creditor
///      is `PortageRouter`; in tests a stand-in credits directly.
contract ConditionalEscrow is IConditionalEscrow, ReentrancyGuard {
    // --- extra fail-closed guards not enumerated in the interface (D6 defense) ---

    /// @dev Condition returned recipients/amounts arrays of differing length (malformed, D6).
    error AllocationLengthMismatch(uint256 recipients, uint256 amounts);
    /// @dev cancel() caller is neither the payer nor a participant of the deal (§4 "unanimous").
    error NotDealParticipant(bytes32 dealId, address caller);

    /// @dev Progress signal for a unanimous cancel (option D): emitted once per distinct approval.
    ///      `participant` is any eligible approver — the payer or a registered participant.
    event CancelApproved(bytes32 indexed dealId, address indexed participant);

    // --- immutable wiring (all Portage core / registry addresses) ---

    /// @notice Portage AppRegistry (immutable core). Read for the D9 controller check (I17).
    AppRegistry public immutable registry;
    /// @notice Portage Ledger (immutable core). Read for the I18 funding check.
    Ledger public immutable ledger;
    /// @notice Portage PayoutEngine (immutable core). Releases principal (SPEC §2.1).
    PayoutEngine public immutable payoutEngine;
    /// @notice Condition allowlist (SPEC §2.2). Gates which conditions may be attached (I9).
    ConditionRegistry public immutable conditionRegistry;
    /// @notice Portage governor; the only caller allowed to sweep unaccounted surplus (D12).
    address public immutable governor;

    // --- per-deal state ---

    struct Deal {
        State state;
        address payer;
        address condition;
        bytes32 appId;
        uint256 amount;
        uint256 hardDeadline;
        address[] participants; // closed payee set registered at open (I11)
        address[] recipients; // resolved allocation snapshot (D5)
        uint256[] amounts; // parallel to recipients
        uint256 claimedCount; // how many snapshot recipients have claimed
        uint256 cancelApprovals; // distinct participant approvals for cancel()
    }

    mapping(bytes32 dealId => Deal) private _deals;
    mapping(bytes32 dealId => mapping(address => bool)) private _isParticipant;
    mapping(bytes32 dealId => mapping(address => bool)) private _claimed;
    mapping(bytes32 dealId => mapping(address => uint256)) private _share; // recipient => allocation
    mapping(bytes32 dealId => mapping(address => bool)) private _hasShare; // recipient => in allocation
    mapping(bytes32 dealId => mapping(address => bool)) private _cancelApproved;

    /// @dev Σ live principal owed per (appId, account); ++ on open, -- on claim/refund/cancel (D12).
    mapping(bytes32 appId => mapping(bytes32 account => uint256)) private _outstanding;

    /// @dev Monotonic counter making each sweep's referenceId unique (D12).
    uint256 private _sweepNonce;

    constructor(
        address registry_,
        address ledger_,
        address payoutEngine_,
        address conditionRegistry_,
        address governor_
    ) {
        registry = AppRegistry(registry_);
        ledger = Ledger(ledger_);
        payoutEngine = PayoutEngine(payoutEngine_);
        conditionRegistry = ConditionRegistry(conditionRegistry_);
        governor = governor_;
    }

    // ---------------------------------------------------------------------
    // open — SPEC §2.1 / §2.1b / D9 / D10
    // ---------------------------------------------------------------------

    /// @inheritdoc IConditionalEscrow
    /// @dev Check order is dictated by the frozen tests: D10 (payer/dealId) → controller (I17) →
    ///      funding (I18) → registry approval (I9). The I18/I19 tests leave the condition
    ///      unapproved yet expect the funding/payer error, so approval must be checked last.
    function open(
        bytes32 appId,
        bytes32 dealId,
        address payer,
        bytes32 salt,
        address condition,
        uint256 amount,
        uint256 hardDeadline,
        address[] calldata participants
    ) external nonReentrant returns (bytes32) {
        if (_deals[dealId].state != State.None) revert DealAlreadyExists(dealId);

        // D10 / I19 / T14 — the payer-committed deal id closes the front-running theft vector.
        if (msg.sender != payer) revert NotPayer(msg.sender, payer);
        bytes32 expected = keccak256(abi.encode(payer, salt, condition, amount, hardDeadline));
        if (dealId != expected) revert DealIdMismatch(dealId, expected);

        // D9 / I17 — the escrow must be able to execute this app's payouts, or funds would trap.
        if (registry.payoutControllerOf(appId) != address(this)) revert EscrowNotController(appId);

        // I18 — funding is verified by reading the Ledger (no callback on deposit, §2.1b).
        uint256 balance = ledger.balanceOf(appId, dealId);
        if (balance < amount) revert DealUnderfunded(dealId, balance, amount);

        // I9 / D3 / T11 — only a registry-approved condition may be attached.
        if (!conditionRegistry.isApproved(condition)) revert ConditionNotApproved(condition);

        Deal storage d = _deals[dealId];
        d.state = State.Funded;
        d.payer = payer;
        d.condition = condition;
        d.appId = appId;
        d.amount = amount;
        d.hardDeadline = hardDeadline;
        for (uint256 i = 0; i < participants.length; i++) {
            d.participants.push(participants[i]);
            _isParticipant[dealId][participants[i]] = true;
        }

        // D11 — amount is fixed here; the balance backs it (surplus, if any, is swept via D12).
        _outstanding[appId][dealId] += amount;

        emit DealOpened(dealId, appId, payer, condition, amount);
        return dealId;
    }

    // ---------------------------------------------------------------------
    // activate — Funded → Resolving (SPEC §4)
    // ---------------------------------------------------------------------

    /// @inheritdoc IConditionalEscrow
    /// @dev Optional marker that the condition is actively running. `resolve()` accepts both
    ///      Funded and Resolving, so activation is never required for liveness.
    function activate(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != State.Funded) revert WrongState(dealId, d.state);
        d.state = State.Resolving;
        emit DealActivated(dealId);
    }

    // ---------------------------------------------------------------------
    // resolve — snapshot the allocation (SPEC §2 D5/D6, §3, I2/I3/I11/I16)
    // ---------------------------------------------------------------------

    /// @inheritdoc IConditionalEscrow
    /// @dev Reads the condition exactly once (D5) via a `view` staticcall and snapshots the
    ///      result. Fails closed (D6): unsettled, malformed, non-summing, or non-participant
    ///      allocations revert — never a partial/default settlement. Succeeds at most once (I3).
    function resolve(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != State.Funded && d.state != State.Resolving) revert WrongState(dealId, d.state);

        // D5 — single read; the outcome is frozen against later condition mutation (I16).
        (bool settled, address[] memory recipients, uint256[] memory amounts) =
            ISettlementCondition(d.condition).resolve(dealId);

        // D6 — fail closed on every malformed shape.
        if (!settled) revert NotSettled(dealId);
        if (recipients.length == 0) revert EmptyAllocation(dealId);
        if (recipients.length != amounts.length) revert AllocationLengthMismatch(recipients.length, amounts.length);

        uint256 sum;
        for (uint256 i = 0; i < recipients.length; i++) {
            address r = recipients[i];
            // I11 / T1 — a condition can never introduce a payee outside the registered set.
            if (!_isParticipant[dealId][r]) revert RecipientNotParticipant(r);
            sum += amounts[i];

            d.recipients.push(r);
            d.amounts.push(amounts[i]);
            _share[dealId][r] = amounts[i];
            _hasShare[dealId][r] = true;
        }

        // I2 / T2 / T3 — exact-sum; over- and under-allocation both revert.
        if (sum != d.amount) revert AllocationSumMismatch(sum, d.amount);

        d.state = State.Resolved;
        emit DealResolved(dealId, recipients.length, sum);
    }

    // ---------------------------------------------------------------------
    // claim — pull one recipient's allocation (SPEC §2.1 D2, I4/I12/I14/I15)
    // ---------------------------------------------------------------------

    /// @inheritdoc IConditionalEscrow
    /// @dev CEI (I14): marks the allocation consumed and decrements `outstanding` BEFORE the
    ///      `PayoutEngine.payout` external call. `nonReentrant` (I15) plus that ordering plus the
    ///      engine's per-`referenceId` one-shot make a double payout impossible three ways over.
    ///      Per-recipient calls isolate a blocked/reverting recipient (D2 / T10).
    function claim(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];

        // I12 — only a designated recipient may claim, and only their own allocation.
        if (!_hasShare[dealId][msg.sender]) revert NoAllocation(dealId, msg.sender);
        // I4 / T4 — at most once per recipient. Checked BEFORE the state guard so the second claim
        // on a fully-claimed single-recipient deal (whose state is already Claimed) reports
        // AlreadyClaimed rather than WrongState.
        if (_claimed[dealId][msg.sender]) revert AlreadyClaimed(dealId, msg.sender);
        // An unclaimed recipient with a share exists only while the deal is Resolved (the deal
        // reaches Claimed only once every share is claimed), so this guard never trips for a
        // legitimate claimant; it backstops claims on any non-Resolved state.
        if (d.state != State.Resolved) revert WrongState(dealId, d.state);

        uint256 amount = _share[dealId][msg.sender];

        // --- effects (before interaction) ---
        _claimed[dealId][msg.sender] = true;
        d.claimedCount += 1;
        if (d.claimedCount == d.recipients.length) d.state = State.Claimed;
        _outstanding[d.appId][dealId] -= amount;

        // --- interaction --- referenceId shape is SPEC §2.1 verbatim.
        payoutEngine.payout(d.appId, dealId, keccak256(abi.encode(dealId, msg.sender)), msg.sender, amount);

        emit AllocationClaimed(dealId, msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // refund — payer recovery after the deadline (SPEC §2 D4, I5/I7/I8)
    // ---------------------------------------------------------------------

    /// @inheritdoc IConditionalEscrow
    /// @dev D4 — makes NO call into the condition, so a bricked/reverting/self-destructed
    ///      condition cannot trap funds (I8). Reachable by the payer alone after `hardDeadline`
    ///      with no cooperation from any counterparty (I7). Mutually exclusive with resolve (I5):
    ///      a Resolved deal is no longer Funded/Resolving, so this reverts WrongState.
    function refund(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != State.Funded && d.state != State.Resolving) revert WrongState(dealId, d.state);
        if (block.timestamp < d.hardDeadline) revert BeforeHardDeadline(dealId, block.timestamp, d.hardDeadline);

        uint256 amount = d.amount;

        // effects
        d.state = State.Refunded;
        _outstanding[d.appId][dealId] -= amount;

        // interaction (payer recovers principal; surplus, if any, remains sweepable via D12)
        payoutEngine.payout(
            d.appId, dealId, keccak256(abi.encode("PORTAGE_REFUND", dealId, d.payer)), d.payer, amount
        );

        emit DealRefunded(dealId, d.payer, amount);
    }

    // ---------------------------------------------------------------------
    // cancel — unanimous pre-resolution unwind (SPEC §4, I6)
    // ---------------------------------------------------------------------

    /// @inheritdoc IConditionalEscrow
    /// @dev Impossible once Resolved (I6): only a Funded deal may be cancelled (option C rejected —
    ///      no Resolving path). SPEC §4 specifies cancel as "unanimous, pre-resolution" but leaves
    ///      the consent set unspecified; the frozen suite exercises only the Resolved→revert guard.
    ///      Interpretation implemented here (approved: option B): the unanimous set is the PAYER
    ///      plus every registered participant. Each eligible approver calls `cancel(dealId)` once;
    ///      each first approval emits `CancelApproved` (option D). On the final approval the deal
    ///      unwinds and the full principal returns to the payer. If the payer is also a
    ///      participant they count once (the threshold de-duplicates them). This happy path is not
    ///      covered by any frozen test.
    function cancel(bytes32 dealId) external nonReentrant {
        Deal storage d = _deals[dealId];
        if (d.state != State.Funded) revert WrongState(dealId, d.state);

        // Eligible approvers: the payer or a registered participant.
        bool isPayer = msg.sender == d.payer;
        if (!isPayer && !_isParticipant[dealId][msg.sender]) revert NotDealParticipant(dealId, msg.sender);

        if (!_cancelApproved[dealId][msg.sender]) {
            _cancelApproved[dealId][msg.sender] = true;
            d.cancelApprovals += 1;
            emit CancelApproved(dealId, msg.sender); // option D — partial-progress signal
        }

        // Unanimity threshold = payer + participants, de-duplicated if the payer is a participant.
        uint256 required = d.participants.length;
        if (!_isParticipant[dealId][d.payer]) required += 1;
        if (d.cancelApprovals != required) return; // not unanimous yet

        uint256 amount = d.amount;

        // effects
        d.state = State.Cancelled;
        _outstanding[d.appId][dealId] -= amount;

        // interaction (unwind: principal returns to the payer)
        payoutEngine.payout(
            d.appId, dealId, keccak256(abi.encode("PORTAGE_CANCEL", dealId, d.payer)), d.payer, amount
        );

        emit DealCancelled(dealId);
    }

    // ---------------------------------------------------------------------
    // sweepUnaccounted — governor recovery of surplus (SPEC §2 D12, I20 / T15)
    // ---------------------------------------------------------------------

    /// @inheritdoc IConditionalEscrow
    /// @dev Pays exactly `ledger.balanceOf(appId, account) - outstanding[appId][account]`. The
    ///      subtraction is what makes it safe: an active deal's principal is `outstanding` and can
    ///      never be swept (I20 / T15). Governor-only (D12). A nonce-derived referenceId lets
    ///      repeated sweeps of the same account not collide.
    function sweepUnaccounted(bytes32 appId, bytes32 account, address to) external nonReentrant {
        if (msg.sender != governor) revert NotGovernor(msg.sender);

        uint256 balance = ledger.balanceOf(appId, account);
        uint256 owed = _outstanding[appId][account];
        // I20 — never reduce balance below outstanding. (balance >= owed always holds; the checked
        // subtraction is a hard backstop if that invariant were ever violated.)
        uint256 surplus = balance - owed;
        if (surplus == 0) revert NothingToSweep(appId, account);

        // outstanding is intentionally NOT decremented — only unaccounted surplus leaves.
        payoutEngine.payout(
            appId, account, keccak256(abi.encode("PORTAGE_SWEEP", appId, account, _sweepNonce++)), to, surplus
        );

        emit Swept(appId, account, to, surplus);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc IConditionalEscrow
    function stateOf(bytes32 dealId) external view returns (State) {
        return _deals[dealId].state;
    }

    /// @inheritdoc IConditionalEscrow
    function appIdOf(bytes32 dealId) external view returns (bytes32) {
        return _deals[dealId].appId;
    }

    /// @inheritdoc IConditionalEscrow
    function payerOf(bytes32 dealId) external view returns (address) {
        return _deals[dealId].payer;
    }

    /// @inheritdoc IConditionalEscrow
    function conditionOf(bytes32 dealId) external view returns (address) {
        return _deals[dealId].condition;
    }

    /// @inheritdoc IConditionalEscrow
    function dealAmount(bytes32 dealId) external view returns (uint256) {
        return _deals[dealId].amount;
    }

    /// @inheritdoc IConditionalEscrow
    function hardDeadlineOf(bytes32 dealId) external view returns (uint256) {
        return _deals[dealId].hardDeadline;
    }

    /// @inheritdoc IConditionalEscrow
    function participantsOf(bytes32 dealId) external view returns (address[] memory) {
        return _deals[dealId].participants;
    }

    /// @inheritdoc IConditionalEscrow
    function allocationOf(bytes32 dealId)
        external
        view
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        Deal storage d = _deals[dealId];
        return (d.recipients, d.amounts);
    }

    /// @inheritdoc IConditionalEscrow
    function claimedOf(bytes32 dealId, address recipient) external view returns (bool) {
        return _claimed[dealId][recipient];
    }

    /// @inheritdoc IConditionalEscrow
    function outstanding(bytes32 appId, bytes32 account) external view returns (uint256) {
        return _outstanding[appId][account];
    }
}
