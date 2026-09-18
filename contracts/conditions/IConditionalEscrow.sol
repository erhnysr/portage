// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title IConditionalEscrow
/// @notice Interface for the Portage conditional-settlement escrow. Signatures follow
///         SPEC.md §2.1 (custody/settlement mechanics), §2.1b (funding path) and §4
///         (state machine). Custody of principal lives in the Portage `Ledger`
///         (`balances[appId][dealId]`), never in this contract (D8).
///
/// @dev Nothing in this interface carries business logic; the reference implementation
///      (`ConditionalEscrow`) is a stub during the failing-first phase (build order §10.3).
///      Custom errors and the `State` enum are declared here so tests and the eventual
///      implementation reference a single source.
interface IConditionalEscrow {
    /// @notice Deal lifecycle — SPEC §4. `None` is the implicit pre-open state.
    enum State {
        None, // never opened
        Funded, // USDC credited to Ledger.balances[appId][dealId], condition attached
        Resolving, // condition actively running (e.g. arena open, jury voting)
        Resolved, // allocation snapshotted; funds claimable
        Claimed, // every allocation withdrawn — terminal
        Refunded, // hard deadline passed with no resolution; payer recovered — terminal
        Cancelled // all participants unwound before resolution — terminal

    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event DealOpened(
        bytes32 indexed dealId, bytes32 indexed appId, address indexed payer, address condition, uint256 amount
    );
    event DealActivated(bytes32 indexed dealId);
    event DealResolved(bytes32 indexed dealId, uint256 recipientCount, uint256 totalAllocated);
    event AllocationClaimed(bytes32 indexed dealId, address indexed recipient, uint256 amount);
    event DealRefunded(bytes32 indexed dealId, address indexed payer, uint256 amount);
    event DealCancelled(bytes32 indexed dealId);
    event Swept(bytes32 indexed appId, bytes32 indexed account, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotPayer(address caller, address payer); // I19 / D10 / T14
    error DealIdMismatch(bytes32 provided, bytes32 expected); // I19 / D10
    error EscrowNotController(bytes32 appId); // I17 / D9
    error DealUnderfunded(bytes32 dealId, uint256 balance, uint256 amount); // I18 / T14
    error ConditionNotApproved(address condition); // I9 / T1 / T11
    error DealAlreadyExists(bytes32 dealId);
    error UnknownDeal(bytes32 dealId);
    error WrongState(bytes32 dealId, State current); // generic state-machine guard (I5/I6/...)
    error NotSettled(bytes32 dealId); // resolve() called while condition not final
    error RecipientNotParticipant(address recipient); // I11 / T1 / D6
    error AllocationSumMismatch(uint256 provided, uint256 expected); // I2 / T2 / T3 / D6
    error EmptyAllocation(bytes32 dealId); // D6 (empty set while claiming settled)
    error NoAllocation(bytes32 dealId, address caller); // I12 (caller has nothing to claim)
    error AlreadyClaimed(bytes32 dealId, address recipient); // I4 / T4
    error BeforeHardDeadline(bytes32 dealId, uint256 nowTs, uint256 deadline); // refund guard / I7
    error NotGovernor(address caller); // D12 (sweep is governor-only) / T15
    error NothingToSweep(bytes32 appId, bytes32 account); // D12 / I20

    // ---------------------------------------------------------------------
    // Lifecycle — SPEC §2.1 / §4
    // ---------------------------------------------------------------------

    /// @notice Open a deal against funds already credited to `Ledger.balances[appId][dealId]`
    ///         by a Gateway deposit (SPEC §2.1b — the escrow receives no callback and verifies
    ///         funding by reading the Ledger balance). Requirements enforced by the impl:
    ///           - `registry.payoutControllerOf(appId) == address(this)`      (I17 / D9)
    ///           - `dealId == keccak256(abi.encode(payer,salt,condition,amount,hardDeadline))`
    ///             and `msg.sender == payer`                                   (I19 / D10 / T14)
    ///           - `condition` approved in the ConditionRegistry               (I9 / T1 / T11)
    ///           - `ledger.balanceOf(appId, dealId) >= amount`                 (I18)
    /// @param participants the closed set of addresses a resolved allocation may pay (I11).
    /// @return dealId the opened deal id (echoes the argument).
    function open(
        bytes32 appId,
        bytes32 dealId,
        address payer,
        bytes32 salt,
        address condition,
        uint256 amount,
        uint256 hardDeadline,
        address[] calldata participants
    ) external returns (bytes32);

    /// @notice Funded → Resolving (SPEC §4). Marks the condition as actively running.
    function activate(bytes32 dealId) external;

    /// @notice Read the condition exactly once (D5) and snapshot the allocation (Funded/Resolving
    ///         → Resolved). Fails closed (D6) if the allocation is malformed. Idempotent-once (I3).
    function resolve(bytes32 dealId) external;

    /// @notice Pull a single recipient's snapshotted allocation via `PayoutEngine.payout`
    ///         (SPEC §2.1). Marks the allocation consumed before the external call (CEI, I14).
    ///         Only the recipient themselves may claim their own allocation (I12).
    function claim(bytes32 dealId) external;

    /// @notice Payer recovery after `hardDeadline` with no resolution (Funded/Resolving →
    ///         Refunded). Makes NO call into the condition (D4). Mutually exclusive with
    ///         resolve (I5).
    function refund(bytes32 dealId) external;

    /// @notice Unanimous pre-resolution unwind (Funded → Cancelled). Impossible once Resolved (I6).
    function cancel(bytes32 dealId) external;

    /// @notice Governor-only recovery of unaccounted surplus (D12): pays
    ///         `ledger.balanceOf(appId,account) - outstanding[appId][account]`. Can never reduce
    ///         the balance below `outstanding` (I20).
    function sweepUnaccounted(bytes32 appId, bytes32 account, address to) external;

    // ---------------------------------------------------------------------
    // Views (needed by invariant assertions and tests)
    // ---------------------------------------------------------------------

    function stateOf(bytes32 dealId) external view returns (State);
    function appIdOf(bytes32 dealId) external view returns (bytes32);
    function payerOf(bytes32 dealId) external view returns (address);
    function conditionOf(bytes32 dealId) external view returns (address);
    function dealAmount(bytes32 dealId) external view returns (uint256);
    function hardDeadlineOf(bytes32 dealId) external view returns (uint256);
    function participantsOf(bytes32 dealId) external view returns (address[] memory);
    function allocationOf(bytes32 dealId)
        external
        view
        returns (address[] memory recipients, uint256[] memory amounts);
    function claimedOf(bytes32 dealId, address recipient) external view returns (bool);
    /// @notice Σ of live principal owed for `(appId, account)`; incremented on open,
    ///         decremented on each claim/refund (D12). The subtrahend I20 protects.
    function outstanding(bytes32 appId, bytes32 account) external view returns (uint256);
}
