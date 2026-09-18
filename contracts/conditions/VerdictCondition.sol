// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ISettlementCondition} from "./ISettlementCondition.sol";
import {IConditionalEscrow} from "./IConditionalEscrow.sol";

/// @notice Minimal read interface over the deployed Coliseum `Arena` (SPEC §7). Only the members
///         `VerdictCondition` needs; the `Submission` struct layout matches `Arena.Submission`
///         exactly so `getSubmission` decodes correctly.
/// @dev `getPhase()` is deliberately NOT declared here — the condition must never read it (T9).
interface IArena {
    struct Submission {
        address submitter;
        string contentRef;
        uint256 votes;
        uint256 submittedAt;
    }

    function finalized() external view returns (bool);
    function getWinners() external view returns (uint256[3] memory);
    function getSubmission(uint256 id) external view returns (Submission memory);
}

/// @title VerdictCondition
/// @notice Settlement condition (SPEC.md §1, §7) that resolves from an on-chain Arena verdict. The
///         payer binds a deal to an Arena; once that Arena is `finalized()`, this condition mirrors
///         the Arena's 60/30/10 prize split (with the same collapse-to-first rule for empty 2nd/3rd
///         slots) onto the escrowed `deal.amount`, paying the winners' submitter addresses. The
///         Arena's own pot is never touched — the Arena is a decision organ only (SPEC §7, D8).
///
/// @dev T9 (SPEC §6): resolution reads `arena.finalized()` and NEVER `arena.getPhase()`. `getPhase`
///      returns `Ended` on `block.timestamp >= votingDeadline` alone, while `finalize()` is
///      permissionless and may lag arbitrarily — so a phase-based read could settle before the
///      verdict is recorded. `finalized`/`winners` are each written exactly once in `finalize()`
///      (SPEC §8.5), so once true the outcome is immutable.
///
///      Split ratios are hardcoded to match `Arena` (its `SPLIT_*` constants are private): 1st
///      6000 bps, 2nd 3000, 3rd 1000. Rounding dust from the floored per-slot amounts is added to
///      the 1st-place allocation (SPEC O1: dust → largest allocation), keeping Σ == deal.amount
///      exactly (I2). Winners' addresses must lie in the escrow participant set — the escrow
///      re-checks I11/I2 at resolve, so a winner outside the set fails closed there.
contract VerdictCondition is ISettlementCondition {
    error NotPayer(bytes32 dealId, address caller);
    error AlreadyInitialized(bytes32 dealId);
    error ZeroAddress();
    error DealNotOpen(bytes32 dealId, IConditionalEscrow.State state);

    event Initialized(bytes32 indexed dealId, address indexed arena);

    // Prize split, basis points — must mirror Arena's private SPLIT_1ST/2ND/3RD (60/30/10).
    uint256 private constant SPLIT_1ST = 6_000;
    uint256 private constant SPLIT_2ND = 3_000;
    uint256 private constant SPLIT_3RD = 1_000;
    uint256 private constant BPS = 10_000;

    /// @notice The escrow this condition serves. Read (never written) for deal identity/params.
    IConditionalEscrow public immutable escrow;

    mapping(bytes32 dealId => bool) public initialized;
    mapping(bytes32 dealId => address) public arenaOf;

    constructor(address escrow_) {
        escrow = IConditionalEscrow(escrow_);
    }

    /// @notice Payer binds a deal to an Arena (once).
    /// @dev Order: AlreadyInitialized → deal Funded/Resolving → caller must be the escrow payer →
    ///      non-zero arena.
    function initialize(bytes32 dealId, address arena) external {
        if (initialized[dealId]) revert AlreadyInitialized(dealId);
        _requireOpen(dealId);
        if (msg.sender != escrow.payerOf(dealId)) revert NotPayer(dealId, msg.sender);
        if (arena == address(0)) revert ZeroAddress();

        initialized[dealId] = true;
        arenaOf[dealId] = arena;
        emit Initialized(dealId, arena);
    }

    /// @inheritdoc ISettlementCondition
    /// @dev Fail-closed: settled=false until the bound Arena is finalized with at least a 1st-place
    ///      winner. Reads `finalized()` only (T9). view, no caller-dependent side effects.
    function resolve(bytes32 dealId)
        external
        view
        returns (bool settled, address[] memory recipients, uint256[] memory amounts)
    {
        if (!initialized[dealId]) return (false, new address[](0), new uint256[](0));

        IArena arena = IArena(arenaOf[dealId]);
        if (!arena.finalized()) return (false, new address[](0), new uint256[](0)); // T9: never getPhase()

        uint256[3] memory w = arena.getWinners();
        if (w[0] == 0) return (false, new address[](0), new uint256[](0)); // no winner → permanent fail-closed

        (recipients, amounts) = _allocate(arena, w, escrow.dealAmount(dealId));
        return (true, recipients, amounts);
    }

    // --- internals ---

    /// @dev Deal must be Funded/Resolving (a Resolved/Refunded/Cancelled deal is untouchable).
    function _requireOpen(bytes32 dealId) private view {
        IConditionalEscrow.State state = escrow.stateOf(dealId);
        if (state != IConditionalEscrow.State.Funded && state != IConditionalEscrow.State.Resolving) {
            revert DealNotOpen(dealId, state);
        }
    }

    /// @dev Mirrors Arena's split: empty 2nd/3rd shares collapse into 1st; floored per-slot dust is
    ///      added to 1st so the total equals `dealAmount` exactly.
    function _splitAmounts(uint256 dealAmount, uint256[3] memory w) private pure returns (uint256[3] memory amt) {
        uint256 bps1 = SPLIT_1ST + (w[1] == 0 ? SPLIT_2ND : 0) + (w[2] == 0 ? SPLIT_3RD : 0);
        amt[0] = (dealAmount * bps1) / BPS;
        amt[1] = w[1] != 0 ? (dealAmount * SPLIT_2ND) / BPS : 0;
        amt[2] = w[2] != 0 ? (dealAmount * SPLIT_3RD) / BPS : 0;
        amt[0] += dealAmount - (amt[0] + amt[1] + amt[2]); // dust → 1st (largest), keeps Σ exact
    }

    /// @dev Resolves winner slots to submitter addresses and de-duplicates (an address appearing in
    ///      more than one slot yields a single recipient with summed amount — the escrow must never
    ///      receive a duplicate recipient). Kept in its own frame to bound the EVM stack.
    function _allocate(IArena arena, uint256[3] memory w, uint256 dealAmount)
        private
        view
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        uint256[3] memory amt = _splitAmounts(dealAmount, w);

        uint256 n = 1 + (w[1] != 0 ? 1 : 0) + (w[2] != 0 ? 1 : 0);
        address[] memory ta = new address[](n);
        uint256[] memory tv = new uint256[](n);
        ta[0] = arena.getSubmission(w[0] - 1).submitter;
        tv[0] = amt[0];
        uint256 k = 1;
        if (w[1] != 0) {
            ta[k] = arena.getSubmission(w[1] - 1).submitter;
            tv[k] = amt[1];
            k++;
        }
        if (w[2] != 0) {
            ta[k] = arena.getSubmission(w[2] - 1).submitter;
            tv[k] = amt[2];
            k++;
        }

        // De-dup into a compacted result.
        address[] memory ur = new address[](n);
        uint256[] memory ua = new uint256[](n);
        uint256 unique;
        for (uint256 i = 0; i < n; i++) {
            bool found;
            for (uint256 j = 0; j < unique; j++) {
                if (ur[j] == ta[i]) {
                    ua[j] += tv[i];
                    found = true;
                    break;
                }
            }
            if (!found) {
                ur[unique] = ta[i];
                ua[unique] = tv[i];
                unique++;
            }
        }

        recipients = new address[](unique);
        amounts = new uint256[](unique);
        for (uint256 i = 0; i < unique; i++) {
            recipients[i] = ur[i];
            amounts[i] = ua[i];
        }
    }
}
