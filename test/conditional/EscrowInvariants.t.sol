// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {EscrowTestBase} from "./EscrowTestBase.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";
import {MockSettlementCondition} from "./mocks/MockSettlementCondition.sol";
import {EvilUSDC} from "./mocks/EvilUSDC.sol";
import {ReentrantRecipient} from "./mocks/ReentrantRecipient.sol";

/// @notice Failing-first invariant tests I1–I20 (SPEC §5). Every test encodes the SPEC-correct
///         behaviour and is RED against the `ConditionalEscrow` stub (which reverts
///         `NotImplemented()` everywhere). Test names carry the invariant number.
///
/// @dev I14/I15 live in {EscrowReentrancyInvariantsTest} below, which needs a callback-capable
///      token. Everything else runs against the real Portage core + MockUSDC from the base.
contract EscrowInvariantsTest is EscrowTestBase {
    MockSettlementCondition internal cond;

    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        super.setUp();
        cond = new MockSettlementCondition();
    }

    // Arrange helper: fund + approve + open a two-party (alice/bob) deal, return its id.
    // NOTE: this reverts at the ConditionRegistry/escrow stub today (NotImplemented) — that is
    // the intended failing-first behaviour for positive-flow tests.
    function _openDeal(bytes32 salt, uint256 amount, uint256 hardDeadline, address[] memory participants)
        internal
        returns (bytes32 dealId)
    {
        dealId = _dealId(payer, salt, address(cond), amount, hardDeadline);
        _fund(dealId, amount);
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, dealId, payer, salt, address(cond), amount, hardDeadline, participants);
    }

    // ----------------------------------------------------------------- I1
    /// I1: Ledger.appBalance(appId) >= Σ outstanding[appId][account] (inequality; surplus allowed).
    function test_I1_appBalanceGeSumOfOutstanding() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 dealA = _openDeal(keccak256("A"), 100e6, dl, _one(alice));
        bytes32 dealB = _openDeal(keccak256("B"), 50e6, dl, _one(bob));

        uint256 sumOutstanding = escrow.outstanding(ESCROW_APP, dealA) + escrow.outstanding(ESCROW_APP, dealB);
        assertGe(ledger.appBalance(ESCROW_APP), sumOutstanding);
    }

    // ----------------------------------------------------------------- I2
    /// I2: for a resolved deal, sum(amounts) == deal.amount exactly.
    function test_I2_resolvedAllocationSumsToDealAmount() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i2"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _two(alice, bob), _amt2(60e6, 40e6));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("i2"), address(cond), AMOUNT, dl, _two(alice, bob));

        escrow.resolve(deal);

        (, uint256[] memory amounts) = escrow.allocationOf(deal);
        uint256 s;
        for (uint256 i = 0; i < amounts.length; i++) {
            s += amounts[i];
        }
        assertEq(s, escrow.dealAmount(deal));
        assertEq(escrow.dealAmount(deal), AMOUNT);
    }

    // ----------------------------------------------------------------- I3
    /// I3: resolve() succeeds at most once per deal.
    function test_I3_resolveRevertsIfAlreadyResolved() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i3"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("i3"), address(cond), AMOUNT, dl, _one(alice));
        escrow.resolve(deal);

        vm.expectRevert(
            abi.encodeWithSelector(IConditionalEscrow.WrongState.selector, deal, IConditionalEscrow.State.Resolved)
        );
        escrow.resolve(deal);
    }

    // ----------------------------------------------------------------- I4
    /// I4: each recipient claims at most once.
    function test_I4_secondClaimBySameRecipientReverts() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i4"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("i4"), address(cond), AMOUNT, dl, _one(alice));
        escrow.resolve(deal);

        vm.prank(alice);
        escrow.claim(deal);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.AlreadyClaimed.selector, deal, alice));
        escrow.claim(deal);
    }

    // ----------------------------------------------------------------- I5
    /// I5: resolve() and refund() are mutually exclusive — no deal is both resolved and refunded.
    function test_I5_refundRevertsAfterResolve() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i5"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("i5"), address(cond), AMOUNT, dl, _one(alice));
        escrow.resolve(deal);

        vm.warp(dl + 1);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(IConditionalEscrow.WrongState.selector, deal, IConditionalEscrow.State.Resolved)
        );
        escrow.refund(deal);
    }

    // ----------------------------------------------------------------- I6
    /// I6: cancel() is impossible once a deal is Resolved.
    function test_I6_cancelRevertsAfterResolved() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i6"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("i6"), address(cond), AMOUNT, dl, _one(alice));
        escrow.resolve(deal);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(IConditionalEscrow.WrongState.selector, deal, IConditionalEscrow.State.Resolved)
        );
        escrow.cancel(deal);
    }

    // ----------------------------------------------------------------- I7
    /// I7 (unpaused case): after hardDeadline the payer alone can reach a terminal state
    ///     (Refunded) with no cooperation from any counterparty or the condition.
    ///     The paused case is documented by test_T13_pauseBlocksRefund_documentedTradeoff.
    function test_I7_payerCanRefundAfterDeadlineWithoutCooperation() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _openDeal(keccak256("i7"), AMOUNT, dl, _one(alice));

        vm.warp(dl + 1);
        uint256 balBefore = usdc.balanceOf(payer);
        vm.prank(payer);
        escrow.refund(deal);

        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Refunded));
        assertEq(usdc.balanceOf(payer), balBefore + AMOUNT);
    }

    // ----------------------------------------------------------------- I8
    /// I8: a condition that always reverts cannot prevent refund (D4 — refund makes no
    ///     call into the condition).
    function test_I8_refundSucceedsDespiteRevertingCondition() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i8"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setRevertOnResolve(true); // condition is bricked forever
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("i8"), address(cond), AMOUNT, dl, _one(alice));

        vm.warp(dl + 1);
        vm.prank(payer);
        escrow.refund(deal);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Refunded));
    }

    // ----------------------------------------------------------------- I9
    /// I9: only a ConditionRegistry-approved condition can be attached at open (NOT approved here).
    function test_I9_openRevertsIfConditionNotApproved() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i9"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        // deliberately DO NOT approve `cond` in the registry.
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.ConditionNotApproved.selector, address(cond)));
        escrow.open(ESCROW_APP, deal, payer, keccak256("i9"), address(cond), AMOUNT, dl, _one(alice));
    }

    // ----------------------------------------------------------------- I10
    /// I10: the condition attached at open is recorded and immutable (the interface exposes no
    ///      setter to change it).
    function test_I10_conditionRecordedAtOpenIsImmutable() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _openDeal(keccak256("i10"), AMOUNT, dl, _one(alice));
        assertEq(escrow.conditionOf(deal), address(cond));
    }

    // ----------------------------------------------------------------- I11
    /// I11: every recipient in a resolved allocation must be a registered participant; a
    ///      condition cannot introduce a new payee.
    function test_I11_resolveRevertsIfConditionReturnsNonParticipant() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i11"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        // condition tries to pay `stranger`, who is NOT in the participant set {alice}.
        cond.setOutcome(true, _one(stranger), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("i11"), address(cond), AMOUNT, dl, _one(alice));

        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.RecipientNotParticipant.selector, stranger));
        escrow.resolve(deal);
    }

    // ----------------------------------------------------------------- I12
    /// I12: only the designated recipient may claim their own allocation.
    function test_I12_claimRevertsForNonRecipient() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i12"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("i12"), address(cond), AMOUNT, dl, _one(alice));
        escrow.resolve(deal);

        vm.prank(stranger); // has no allocation
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NoAllocation.selector, deal, stranger));
        escrow.claim(deal);
    }

    // ----------------------------------------------------------------- I13
    /// I13: hardDeadline is set at open and cannot be extended/shortened (no setter exists).
    function test_I13_hardDeadlineRecordedAtOpenIsImmutable() public {
        uint256 dl = block.timestamp + 7 days;
        bytes32 deal = _openDeal(keccak256("i13"), AMOUNT, dl, _one(alice));
        assertEq(escrow.hardDeadlineOf(deal), dl);
    }

    // ----------------------------------------------------------------- I16
    /// I16: a deal resolved at block N yields the identical allocation at N+k, regardless of
    ///      any condition state change in between (D5 snapshot).
    function test_I16_resolvedAllocationStableAcrossBlocks() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i16"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("i16"), address(cond), AMOUNT, dl, _one(alice));
        escrow.resolve(deal);

        (address[] memory r1, uint256[] memory a1) = escrow.allocationOf(deal);

        // Mutate the condition AFTER resolution and move forward in time/blocks.
        cond.setOutcome(true, _one(bob), _amt1(AMOUNT));
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 1000);

        (address[] memory r2, uint256[] memory a2) = escrow.allocationOf(deal);
        assertEq(r1.length, r2.length);
        assertEq(r1[0], r2[0]);
        assertEq(a1[0], a2[0]);
    }

    // ----------------------------------------------------------------- I17
    /// I17 / D9: open reverts unless registry.payoutControllerOf(appId) == escrow.
    ///     FOREIGN_APP is registered with `stranger` as controller, not the escrow.
    function test_I17_openRevertsIfEscrowNotPayoutController() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i17"), address(cond), AMOUNT, dl);
        // Fund under FOREIGN_APP so the funding check (I18) is not what trips first.
        ledger.credit(FOREIGN_APP, deal, AMOUNT, keccak256("gw-foreign"));
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.EscrowNotController.selector, FOREIGN_APP));
        escrow.open(FOREIGN_APP, deal, payer, keccak256("i17"), address(cond), AMOUNT, dl, _one(alice));
    }

    // ----------------------------------------------------------------- I18
    /// I18: open reverts unless ledger.balanceOf(appId, dealId) >= amount at call time.
    function test_I18_openRevertsIfUnderfunded() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i18"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT - 1); // one unit short
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.DealUnderfunded.selector, deal, AMOUNT - 1, AMOUNT));
        escrow.open(ESCROW_APP, deal, payer, keccak256("i18"), address(cond), AMOUNT, dl, _one(alice));
    }

    // ----------------------------------------------------------------- I19 (a)
    /// I19 / D10 / T14: open reverts unless msg.sender == payer.
    function test_I19_openRevertsIfCallerIsNotPayer() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("i19a"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        vm.prank(stranger); // not the payer committed in the dealId
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NotPayer.selector, stranger, payer));
        escrow.open(ESCROW_APP, deal, payer, keccak256("i19a"), address(cond), AMOUNT, dl, _one(alice));
    }

    // ----------------------------------------------------------------- I19 (b)
    /// I19 / D10: open reverts unless the provided dealId equals the payer-committed hash.
    function test_I19_openRevertsIfDealIdMismatch() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 expected = _dealId(payer, keccak256("i19b"), address(cond), AMOUNT, dl);
        bytes32 wrong = keccak256("a-different-dealid");
        // Fund the wrong id so the funding check passes and the id-mismatch is what trips.
        ledger.credit(ESCROW_APP, wrong, AMOUNT, keccak256("gw-wrong"));
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.DealIdMismatch.selector, wrong, expected));
        escrow.open(ESCROW_APP, wrong, payer, keccak256("i19b"), address(cond), AMOUNT, dl, _one(alice));
    }

    // ----------------------------------------------------------------- I20 (a)
    /// I20: sweepUnaccounted can never reduce balance below outstanding — an active deal with
    ///      no surplus has nothing to sweep.
    function test_I20_sweepCannotTouchActiveDealPrincipal() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _openDeal(keccak256("i20a"), AMOUNT, dl, _one(alice));

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NothingToSweep.selector, ESCROW_APP, deal));
        escrow.sweepUnaccounted(ESCROW_APP, deal, stranger);

        assertGe(ledger.balanceOf(ESCROW_APP, deal), escrow.outstanding(ESCROW_APP, deal));
    }

    // ----------------------------------------------------------------- I20 (b)
    /// I20 / D11 / D12: only unaccounted surplus (a late credit) is sweepable; the deal's
    ///      principal (outstanding) is never reduced.
    function test_I20_sweepRemovesOnlySurplus() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _openDeal(keccak256("i20b"), AMOUNT, dl, _one(alice));

        // A late credit lands on the open deal (D11): unaccounted surplus.
        uint256 surplus = 25e6;
        ledger.credit(ESCROW_APP, deal, surplus, keccak256("late-credit"));

        uint256 outstandingBefore = escrow.outstanding(ESCROW_APP, deal);
        vm.prank(governor);
        escrow.sweepUnaccounted(ESCROW_APP, deal, stranger);

        assertEq(escrow.outstanding(ESCROW_APP, deal), outstandingBefore); // principal untouched
        assertEq(ledger.balanceOf(ESCROW_APP, deal), outstandingBefore); // only surplus left the vault
        assertEq(usdc.balanceOf(stranger), surplus);
    }
}

/// @notice I14 / I15 — CEI ordering and reentrancy. Uses {EvilUSDC} (a callback-capable token)
///         to drive a reentrant claim. Real USDC has no such callback (D1); this is a
///         defence-in-depth stress test of the escrow's mark-before-call ordering and guard.
contract EscrowReentrancyInvariantsTest is EscrowTestBase {
    EvilUSDC internal evil;
    MockSettlementCondition internal cond;
    ReentrantRecipient internal attacker;

    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        evil = new EvilUSDC();
        _setUpCore(address(evil)); // wire real core against the hostile token
        cond = new MockSettlementCondition();
        attacker = new ReentrantRecipient(escrow);
    }

    // Arrange a resolved single-recipient deal whose recipient is the reentrant attacker, then
    // arm the token callback. Reverts at the stub today (NotImplemented) — failing-first.
    function _armedResolvedDeal() internal returns (bytes32 deal) {
        uint256 dl = block.timestamp + 1 days;
        bytes32 salt = keccak256("reentry");
        deal = _dealId(payer, salt, address(cond), AMOUNT, dl);
        // fund via the stand-in creditor (this contract) using the hostile token
        ledger.credit(ESCROW_APP, deal, AMOUNT, keccak256("gw-reentry"));
        cond.setOutcome(true, _one(address(attacker)), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, salt, address(cond), AMOUNT, dl, _one(address(attacker)));
        escrow.resolve(deal);
        attacker.arm(deal);
        evil.setReentrantHook(address(attacker));
    }

    /// I14: claim marks the allocation consumed BEFORE the external transfer. Proven by the
    ///      reentrant inner claim (fired during the transfer) failing — so exactly one payout
    ///      occurs. If the mark happened after the call, the inner claim would double-pay.
    function test_I14_claimMarksConsumedBeforeExternalCall() public {
        bytes32 deal = _armedResolvedDeal();
        attacker.claim();
        assertTrue(attacker.reentered(), "reentry should have been attempted");
        assertTrue(escrow.claimedOf(deal, address(attacker)));
        assertEq(evil.balanceOf(address(attacker)), AMOUNT); // paid exactly once, not twice
    }

    /// I15: a reentrant call during a transfer cannot produce a second payout.
    function test_I15_reentrantClaimCannotProduceSecondPayout() public {
        bytes32 deal = _armedResolvedDeal();
        attacker.claim();
        // Net paid is exactly the allocation — the reentrant attempt yielded nothing extra.
        assertEq(evil.balanceOf(address(attacker)), AMOUNT);
        assertEq(ledger.balanceOf(ESCROW_APP, deal), 0);
    }
}
