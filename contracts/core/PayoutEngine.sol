// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AppRegistry} from "./AppRegistry.sol";
import {Ledger} from "./Ledger.sol";

/// @title PayoutEngine
/// @notice On-demand payout authorization layer of PortageCore. Applications trigger payouts
///         against their own isolated Ledger balance; this contract verifies the caller is the
///         app's registered `payoutController`, enforces per-`referenceId` idempotency, and
///         asks the Ledger to debit + release USDC.
///
/// @dev Part of the immutable PortageCore. Holds NO funds and has NO admin — it is pure
///      authorization + orchestration. It must be wired as the Ledger's `debitor`.
///
///      App isolation: a controller is bound to its `appId` in the AppRegistry, so it can only
///      ever move that app's funds. The pause check lives in `Ledger.debit` (single source of
///      truth); a paused app's payouts revert there.
contract PayoutEngine is ReentrancyGuard {
    AppRegistry public immutable registry;
    Ledger public immutable ledger;

    /// @notice settled[appId][referenceId] — a payout reference may be executed at most once.
    mapping(bytes32 appId => mapping(bytes32 referenceId => bool used)) public settled;

    event PaidOut(
        bytes32 indexed appId, bytes32 indexed account, bytes32 indexed referenceId, address recipient, uint256 amount
    );
    event Distributed(
        bytes32 indexed appId, bytes32 indexed account, bytes32 indexed referenceId, uint256 totalAmount, uint256 count
    );

    error AppNotRegistered(bytes32 appId);
    error NotPayoutController(bytes32 appId, address caller);
    error AlreadySettled(bytes32 appId, bytes32 referenceId);
    error EmptyBatch();
    error LengthMismatch(uint256 recipients, uint256 amounts);

    constructor(address registry_, address ledger_) {
        registry = AppRegistry(registry_);
        ledger = Ledger(ledger_);
    }

    /// @dev Reverts unless `msg.sender` is the app's registered payout controller.
    modifier onlyPayoutController(bytes32 appId) {
        if (!registry.isRegistered(appId)) revert AppNotRegistered(appId);
        if (msg.sender != registry.payoutControllerOf(appId)) revert NotPayoutController(appId, msg.sender);
        _;
    }

    /// @notice Pay out a single recipient from an app sub-account.
    /// @param appId        The app (caller must be its payout controller).
    /// @param account      Sub-account to debit (e.g. an arena id).
    /// @param referenceId  App-side idempotency key (e.g. an order/round id). One-shot.
    /// @param recipient    USDC recipient.
    /// @param amount       Atomic USDC units.
    function payout(bytes32 appId, bytes32 account, bytes32 referenceId, address recipient, uint256 amount)
        external
        onlyPayoutController(appId)
        nonReentrant
    {
        _markSettled(appId, referenceId);

        // Zero amount/recipient and pause/balance checks are enforced by Ledger.debit.
        ledger.debit(appId, account, amount, recipient);

        emit PaidOut(appId, account, referenceId, recipient, amount);
    }

    /// @notice Pay out multiple recipients from an app sub-account in one atomic call
    ///         (e.g. arena reward distribution). If any single debit fails, the whole batch
    ///         reverts and the `referenceId` remains unsettled.
    function distribute(
        bytes32 appId,
        bytes32 account,
        bytes32 referenceId,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external onlyPayoutController(appId) nonReentrant {
        uint256 n = recipients.length;
        if (n == 0) revert EmptyBatch();
        if (n != amounts.length) revert LengthMismatch(n, amounts.length);

        _markSettled(appId, referenceId);

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            ledger.debit(appId, account, amounts[i], recipients[i]);
            total += amounts[i];
        }

        emit Distributed(appId, account, referenceId, total, n);
    }

    /// @dev Marks a referenceId settled (effects before Ledger interactions). Because this
    ///      write is part of the same transaction as the debits, a revert anywhere in the
    ///      call rolls it back — so a failed batch does not consume the referenceId.
    function _markSettled(bytes32 appId, bytes32 referenceId) private {
        if (settled[appId][referenceId]) revert AlreadySettled(appId, referenceId);
        settled[appId][referenceId] = true;
    }
}
