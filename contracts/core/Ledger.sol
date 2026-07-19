// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AppRegistry} from "./AppRegistry.sol";

/// @title Ledger
/// @notice The USDC vault and per-app accounting core of Portage. Holds all integrated
///         apps' USDC and tracks balances partitioned by `appId` then `account`.
///
/// @dev Part of the immutable PortageCore. App isolation is enforced structurally: no
///      function can move value from one appId's namespace into another's.
///
///      Money flow:
///        - `credit`: called by the creditor (PortageRouter, wired later). Pulls USDC from
///          the caller into this vault and credits balances[appId][account]. This keeps the
///          solvency invariant true by construction: every credited unit is a real token held.
///        - `debit`: called by the debitor (PayoutEngine, wired later). Decrements
///          balances[appId][account] and pushes USDC out to a recipient. Blocked while the
///          app is paused.
///
///      Invariants (see LedgerInvariant.t.sol):
///        I1  USDC.balanceOf(this) >= custodyTotal                (solvency)
///        I2  custodyTotal == Σ appTotal[app]                     (aggregation)
///        I3  appTotal[app] == Σ balances[app][account]           (app-level aggregation)
///        I4  no state transition moves value across appIds       (isolation)
contract Ledger is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice The USDC token this ledger custodies. Immutable.
    IERC20 public immutable usdc;

    /// @notice The app identity/access registry. Immutable.
    AppRegistry public immutable registry;

    /// @notice The only address allowed to `credit` (the PortageRouter). Set by governor.
    address public creditor;

    /// @notice The only address allowed to `debit` (the PayoutEngine). Set by governor.
    address public debitor;

    /// @notice balances[appId][account] — atomic USDC units held for an app sub-account.
    mapping(bytes32 appId => mapping(bytes32 account => uint256 balance)) private _balances;

    /// @notice Σ over accounts of balances[appId][account].
    mapping(bytes32 appId => uint256 total) private _appTotal;

    /// @notice Σ over apps of _appTotal[appId]. Must be backed 1:1 by held USDC (I1).
    uint256 public custodyTotal;

    /// @notice Lifetime counters per app (monotonic; for reconciliation / audit).
    mapping(bytes32 appId => uint256 credited) public totalCredited;
    mapping(bytes32 appId => uint256 paid) public totalPaid;

    /// @notice Inbound idempotency: a Gateway transfer's spec hash may be credited once.
    mapping(bytes32 transferId => bool used) public creditProcessed;

    event CreditorUpdated(address indexed oldCreditor, address indexed newCreditor);
    event DebitorUpdated(address indexed oldDebitor, address indexed newDebitor);
    event Credited(bytes32 indexed appId, bytes32 indexed account, uint256 amount, bytes32 indexed transferId);
    event Debited(bytes32 indexed appId, bytes32 indexed account, uint256 amount, address indexed to);

    error ZeroAddress();
    error NotCreditor(address caller);
    error NotDebitor(address caller);
    error AppNotRegistered(bytes32 appId);
    error AppPaused(bytes32 appId);
    error ZeroAmount();
    error TransferAlreadyProcessed(bytes32 transferId);
    error InsufficientAppBalance(bytes32 appId, bytes32 account, uint256 requested, uint256 available);

    modifier onlyCreditor() {
        if (msg.sender != creditor) revert NotCreditor(msg.sender);
        _;
    }

    modifier onlyDebitor() {
        if (msg.sender != debitor) revert NotDebitor(msg.sender);
        _;
    }

    constructor(address governor_, address usdc_, address registry_) Ownable(governor_) {
        // governor_ == address(0) is rejected by Ownable's constructor (OwnableInvalidOwner).
        if (usdc_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        registry = AppRegistry(registry_);
    }

    // ---------------------------------------------------------------------
    // Governor wiring
    // ---------------------------------------------------------------------

    function setCreditor(address newCreditor) external onlyOwner {
        if (newCreditor == address(0)) revert ZeroAddress();
        emit CreditorUpdated(creditor, newCreditor);
        creditor = newCreditor;
    }

    function setDebitor(address newDebitor) external onlyOwner {
        if (newDebitor == address(0)) revert ZeroAddress();
        emit DebitorUpdated(debitor, newDebitor);
        debitor = newDebitor;
    }

    // ---------------------------------------------------------------------
    // Value flow
    // ---------------------------------------------------------------------

    /// @notice Credit an app sub-account. Pulls `amount` USDC from the caller (the creditor,
    ///         which has just received the minted USDC) into this vault.
    /// @dev CEI: the token pull happens before state is mutated, so a re-entrant callback
    ///      would observe pre-credit state and cannot double-spend; `nonReentrant` adds belt.
    /// @param appId       Target application (must be registered).
    /// @param account     Sub-account within the app (app-defined, e.g. an arena id).
    /// @param amount      Atomic USDC units.
    /// @param transferId  Gateway spec hash; enforces credit-once idempotency.
    function credit(bytes32 appId, bytes32 account, uint256 amount, bytes32 transferId)
        external
        onlyCreditor
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (!registry.isRegistered(appId)) revert AppNotRegistered(appId);
        if (creditProcessed[transferId]) revert TransferAlreadyProcessed(transferId);

        // Interaction first: pull the real tokens that back this credit.
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Effects.
        creditProcessed[transferId] = true;
        _balances[appId][account] += amount;
        _appTotal[appId] += amount;
        custodyTotal += amount;
        totalCredited[appId] += amount;

        emit Credited(appId, account, amount, transferId);
    }

    /// @notice Debit an app sub-account and push USDC to a recipient. Called by the
    ///         PayoutEngine, which has already authorized the payout against the app's
    ///         payoutController. Blocked while the app is paused.
    /// @dev CEI + nonReentrant. Balances are decremented before the outbound transfer.
    function debit(bytes32 appId, bytes32 account, uint256 amount, address to)
        external
        onlyDebitor
        nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (registry.isPaused(appId)) revert AppPaused(appId);

        uint256 available = _balances[appId][account];
        if (amount > available) revert InsufficientAppBalance(appId, account, amount, available);

        // Effects.
        unchecked {
            _balances[appId][account] = available - amount;
            _appTotal[appId] -= amount;
            custodyTotal -= amount;
        }
        totalPaid[appId] += amount;

        // Interaction.
        usdc.safeTransfer(to, amount);

        emit Debited(appId, account, amount, to);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function balanceOf(bytes32 appId, bytes32 account) external view returns (uint256) {
        return _balances[appId][account];
    }

    function appBalance(bytes32 appId) external view returns (uint256) {
        return _appTotal[appId];
    }
}
