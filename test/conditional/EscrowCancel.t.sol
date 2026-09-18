// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {EscrowTestBase} from "./EscrowTestBase.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";
import {ConditionalEscrow} from "../../contracts/conditions/ConditionalEscrow.sol";
import {MockSettlementCondition} from "./mocks/MockSettlementCondition.sol";

/// @notice Unit tests for `ConditionalEscrow.cancel()` — the unanimous pre-resolution unwind
///         (SPEC §4). The unanimous set is the PAYER plus every registered participant (option B,
///         approved out of band): each approves once, the final approval unwinds the deal and
///         returns the full principal to the payer. `CancelApproved` (option D) signals each
///         distinct approval. `cancel()` is Funded-only (I6); option C — extending to Resolving —
///         was rejected.
///
/// @dev The happy path is not covered by the frozen suite (which only asserts the
///      Resolved→WrongState guard in `test_I6_...`); this file adds that coverage. It extends
///      {EscrowTestBase} and follows the existing pattern: real Portage core + MockUSDC, escrow
///      wired as the app's payout controller, a MockSettlementCondition attached (cancel never
///      calls into it — resolution is not involved).
contract EscrowCancelTest is EscrowTestBase {
    MockSettlementCondition internal cond;

    uint256 internal constant AMOUNT = 100e6;

    /// @dev Local mirror of ConditionalEscrow's contract-level event, so `vm.expectEmit` has a
    ///      matching declaration to emit. Signature must stay identical to the contract's.
    event CancelApproved(bytes32 indexed dealId, address indexed participant);

    function setUp() public override {
        super.setUp();
        cond = new MockSettlementCondition();
    }

    /// @dev Fund + approve + open a Funded deal with the given participant set. Payer is the
    ///      base fixture's `payer` (distinct from alice/bob), so the cancel quorum is
    ///      participants + payer.
    function _open(bytes32 salt, address[] memory participants) internal returns (bytes32 deal) {
        uint256 dl = block.timestamp + 365 days;
        deal = _dealId(payer, salt, address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, salt, address(cond), AMOUNT, dl, participants);
    }

    // ----------------------------------------------------------------- (1)
    /// Happy path: alice, bob, then payer each approve; the payer's final approval flips the deal
    /// to Cancelled and returns the whole principal to the payer.
    function test_cancel_happyPath_unanimousReturnsPrincipalToPayer() public {
        bytes32 deal = _open(keccak256("happy"), _two(alice, bob));
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(alice);
        escrow.cancel(deal);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Funded), "after alice: still Funded");

        vm.prank(bob);
        escrow.cancel(deal);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Funded), "after bob: still Funded");

        vm.prank(payer);
        escrow.cancel(deal); // final approver (payer completes the quorum)

        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Cancelled), "final: Cancelled");
        assertEq(usdc.balanceOf(payer), payerBefore + AMOUNT, "principal returned to payer");
        assertEq(ledger.balanceOf(ESCROW_APP, deal), 0, "ledger sub-account drained");
        assertEq(escrow.outstanding(ESCROW_APP, deal), 0, "outstanding cleared");
    }

    // ----------------------------------------------------------------- (2)
    /// Missing approval: with the payer not yet approving, the deal stays Funded and no funds move.
    function test_cancel_incompleteQuorum_staysFundedNoTransfer() public {
        bytes32 deal = _open(keccak256("incomplete"), _two(alice, bob));
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(alice);
        escrow.cancel(deal);
        vm.prank(bob);
        escrow.cancel(deal);
        // payer has NOT approved → quorum (alice, bob, payer) is incomplete.

        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Funded), "still Funded");
        assertEq(usdc.balanceOf(payer), payerBefore, "no transfer while incomplete");
        assertEq(ledger.balanceOf(ESCROW_APP, deal), AMOUNT, "principal untouched");
    }

    // ----------------------------------------------------------------- (3)
    /// Unauthorized caller: a non-payer, non-participant is rejected with NotDealParticipant.
    function test_cancel_unauthorizedCallerReverts() public {
        bytes32 deal = _open(keccak256("unauth"), _two(alice, bob));

        vm.prank(stranger); // neither payer nor a participant
        vm.expectRevert(abi.encodeWithSelector(ConditionalEscrow.NotDealParticipant.selector, deal, stranger));
        escrow.cancel(deal);
    }

    // ----------------------------------------------------------------- (4)
    /// I6 regression: cancel() is impossible once the deal is Resolved.
    function test_cancel_revertsAfterResolved() public {
        bytes32 deal = _open(keccak256("resolved"), _one(alice));
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        escrow.resolve(deal);

        vm.prank(alice); // a participant, but the deal is past Funded
        vm.expectRevert(
            abi.encodeWithSelector(IConditionalEscrow.WrongState.selector, deal, IConditionalEscrow.State.Resolved)
        );
        escrow.cancel(deal);
    }

    // ----------------------------------------------------------------- (5)
    /// Duplicate approval is a no-op (not a revert) and is de-duplicated: alice approving twice
    /// counts once, so the quorum still requires bob AND payer. Proven by the deal remaining
    /// Funded after {alice, alice, bob} and only unwinding once the payer approves.
    function test_cancel_duplicateApprovalIsNoOpAndDeduped() public {
        bytes32 deal = _open(keccak256("dup"), _two(alice, bob));

        vm.prank(alice);
        escrow.cancel(deal);

        // Duplicate call by the same approver: must NOT revert and must emit nothing / move nothing.
        vm.recordLogs();
        vm.prank(alice);
        escrow.cancel(deal);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "duplicate approval emits no event");
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Funded), "still Funded after dup");

        vm.prank(bob);
        escrow.cancel(deal);
        // If the duplicate had double-counted, {alice, alice, bob} would total the 3-quorum and
        // finalize here. It must NOT — the payer still owes an approval.
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Funded), "dedup: not yet unanimous");

        uint256 payerBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        escrow.cancel(deal);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Cancelled), "payer completes quorum");
        assertEq(usdc.balanceOf(payer), payerBefore + AMOUNT, "principal returned once");
    }

    // ----------------------------------------------------------------- (6)
    /// CancelApproved is emitted once per distinct approval, carrying (dealId, approver).
    function test_cancel_emitsCancelApprovedPerApproval() public {
        bytes32 deal = _open(keccak256("event"), _two(alice, bob));

        vm.expectEmit(true, true, false, true, address(escrow));
        emit CancelApproved(deal, alice);
        vm.prank(alice);
        escrow.cancel(deal);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit CancelApproved(deal, bob);
        vm.prank(bob);
        escrow.cancel(deal);

        // Payer's approval both emits CancelApproved and finalizes (DealCancelled also fires; a
        // single expectEmit only asserts the CancelApproved log is present among the emitted logs).
        vm.expectEmit(true, true, false, true, address(escrow));
        emit CancelApproved(deal, payer);
        vm.prank(payer);
        escrow.cancel(deal);

        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Cancelled), "finalized after payer");
    }
}
