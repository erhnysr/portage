// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {EscrowTestBase} from "./EscrowTestBase.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";
import {MockSettlementCondition} from "./mocks/MockSettlementCondition.sol";
import {EvilUSDC} from "./mocks/EvilUSDC.sol";
import {ReentrantRecipient} from "./mocks/ReentrantRecipient.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";

/// @notice Failing-first negative tests for the SPEC §6 threat model (T1–T15). Each proves the
///         attack FAILS (or documents an explicitly accepted/closed threat per the SPEC). All
///         are RED against the stub. Test names carry the threat number.
///
/// @dev T7 and T10 need a callback/blocklist-capable token and live in {EscrowThreatsTokenTest}.
contract EscrowThreatsTest is EscrowTestBase {
    MockSettlementCondition internal cond;
    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        super.setUp();
        cond = new MockSettlementCondition();
    }

    function _openWith(bytes32 salt, uint256 dl, address[] memory participants) internal returns (bytes32 deal) {
        deal = _dealId(payer, salt, address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, salt, address(cond), AMOUNT, dl, participants);
    }

    // ----------------------------------------------------------------- T1
    /// T1: a malicious condition names itself/an attacker (outside the participant set) as
    ///     recipient. Mitigated by I11 subset check + I9 registry gating: resolve reverts.
    function test_T1_conditionCannotIntroduceForeignRecipient() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("t1"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(address(cond)), _amt1(AMOUNT)); // pays itself
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("t1"), address(cond), AMOUNT, dl, _one(alice));

        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.RecipientNotParticipant.selector, address(cond)));
        escrow.resolve(deal);
    }

    // ----------------------------------------------------------------- T2
    /// T2: amounts summing ABOVE the deal are rejected (I2 exact-sum, fail-closed D6).
    function test_T2_overAllocationReverts() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("t2"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _two(alice, bob), _amt2(70e6, 40e6)); // 110e6 > 100e6
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("t2"), address(cond), AMOUNT, dl, _two(alice, bob));

        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.AllocationSumMismatch.selector, 110e6, AMOUNT));
        escrow.resolve(deal);
    }

    // ----------------------------------------------------------------- T3
    /// T3: amounts summing BELOW the deal are rejected too — residue is not silently retained.
    function test_T3_underAllocationReverts() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("t3"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _two(alice, bob), _amt2(60e6, 30e6)); // 90e6 < 100e6
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("t3"), address(cond), AMOUNT, dl, _two(alice, bob));

        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.AllocationSumMismatch.selector, 90e6, AMOUNT));
        escrow.resolve(deal);
    }

    // ----------------------------------------------------------------- T4
    /// T4: double claim is rejected (I4 + escrow mark-before-call + PayoutEngine referenceId).
    function test_T4_doubleClaimReverts() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("t4"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("t4"), address(cond), AMOUNT, dl, _one(alice));
        escrow.resolve(deal);

        vm.prank(alice);
        escrow.claim(deal);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.AlreadyClaimed.selector, deal, alice));
        escrow.claim(deal);
    }

    // ----------------------------------------------------------------- T5
    /// T5: griefing — a counterparty never triggers the condition. The payer is not stuck:
    ///     after the hard deadline they refund unilaterally (I7).
    function test_T5_payerRefundsWhenConditionNeverResolves() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _openWith(keccak256("t5"), dl, _one(alice));
        // condition stays unsettled forever (never configured to settle)

        vm.warp(dl + 1);
        vm.prank(payer);
        escrow.refund(deal);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Refunded));
    }

    // ----------------------------------------------------------------- T6
    /// T6: a condition bricked/reverting forever cannot trap funds — refund makes no call into
    ///     it (D4 + I8).
    function test_T6_refundWorksWhenConditionAlwaysReverts() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("t6"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setRevertOnResolve(true);
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("t6"), address(cond), AMOUNT, dl, _one(alice));

        vm.warp(dl + 1);
        vm.prank(payer);
        escrow.refund(deal);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Refunded));
    }

    // ----------------------------------------------------------------- T8
    /// T8: front-running resolve() to land a different outcome. resolve is permissionless, but
    ///     the outcome is determined by condition state (D5 snapshot), not by who calls or when;
    ///     and it can happen at most once (I3). A stranger resolving cannot redirect funds.
    function test_T8_resolveOutcomeIsConditionDefinedNotCallerDefined() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("t8"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("t8"), address(cond), AMOUNT, dl, _one(alice));

        // A stranger front-runs the resolve call.
        vm.prank(stranger);
        escrow.resolve(deal);

        // Outcome is the condition's (alice), not the caller's.
        (address[] memory r,) = escrow.allocationOf(deal);
        assertEq(r[0], alice);

        // And a second resolve (by anyone) is rejected.
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IConditionalEscrow.WrongState.selector, deal, IConditionalEscrow.State.Resolved)
        );
        escrow.resolve(deal);
    }

    // ----------------------------------------------------------------- T9 (DEFERRED per SPEC)
    /// T9: a verdict flips between the arena's finalisation and the escrow's read. The SPEC's
    ///     own build order (§10.9/§10.10) puts VerdictCondition and the executed adversarial
    ///     interleaving test AFTER this failing-first step, and requires the deployed Arena,
    ///     which is not part of this session's scope. Deferred per SPEC — NOT fabricated here.
    function test_T9_verdictReadsFinalizedNotPhase_DEFERRED() public {
        vm.skip(true);
    }

    // ----------------------------------------------------------------- T11
    /// T11: the registry owner approving a malicious condition is an ACCEPTED, documented trust
    ///     assumption for v1 (mitigation = v2 timelock in ConditionRegistry). What IS enforced
    ///     is the boundary: a condition NOT approved in the registry can never be attached.
    function test_T11_onlyRegistryApprovedConditionsCanAttach() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("t11"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        // `cond` is deliberately not approved.
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.ConditionNotApproved.selector, address(cond)));
        escrow.open(ESCROW_APP, deal, payer, keccak256("t11"), address(cond), AMOUNT, dl, _one(alice));
    }

    // ----------------------------------------------------------------- T12
    /// T12: closed per SPEC §8.1 — the cross-chain leg is deposit-side only; release is entirely
    ///     same-chain on Arc. This test proves release completes on-chain (recipient's local USDC
    ///     balance rises via Ledger.debit -> safeTransfer) with no post-claim cross-chain step.
    function test_T12_releaseIsSameChainWithNoPostClaimLeg() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _dealId(payer, keccak256("t12"), address(cond), AMOUNT, dl);
        _fund(deal, AMOUNT);
        cond.setOutcome(true, _one(alice), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("t12"), address(cond), AMOUNT, dl, _one(alice));
        escrow.resolve(deal);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        escrow.claim(deal);
        assertEq(usdc.balanceOf(alice), before + AMOUNT); // fully released, same chain
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Claimed));
    }

    // ----------------------------------------------------------------- T13
    /// T13: a guardian pause blocks refund — an ACCEPTED, documented trade-off (§2.1). The pause
    ///     is an emergency stop; a pause-bypassing refund would be the worse failure mode. This
    ///     test documents the behaviour: paused -> refund reverts; unpaused -> refund works.
    function test_T13_pauseBlocksRefund_documentedTradeoff() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _openWith(keccak256("t13"), dl, _one(alice));
        vm.warp(dl + 1);

        // Guardian emergency-pauses the escrow app.
        vm.prank(guardian);
        registry.setAppPaused(ESCROW_APP, true);

        // Refund is blocked at Ledger.debit while paused (weakens I7 during a pause — documented).
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(Ledger.AppPaused.selector, ESCROW_APP));
        escrow.refund(deal);

        // Once the app owner unpauses, the payer recovers funds.
        vm.prank(appOwner);
        registry.setAppPaused(ESCROW_APP, false);
        vm.prank(payer);
        escrow.refund(deal);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Refunded));
    }

    // ----------------------------------------------------------------- T14
    /// T14: an attacker front-runs open() on a funded-but-un-opened dealId, naming themselves
    ///     recipient. The dealId commits to the payer (D10); to match the funded account the
    ///     attacker must pass the real payer, but then `msg.sender == payer` fails. I19.
    function test_T14_frontRunnerCannotStealFundedDeposit() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 salt = keccak256("t14");
        bytes32 deal = _dealId(payer, salt, address(cond), AMOUNT, dl); // committed to the real payer
        _fund(deal, AMOUNT);
        vm.prank(governor);
        condReg.setApproved(address(cond), true);

        // Attacker tries to open the funded deal with themselves as sole recipient.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NotPayer.selector, stranger, payer));
        escrow.open(ESCROW_APP, deal, payer, salt, address(cond), AMOUNT, dl, _one(stranger));
    }

    // ----------------------------------------------------------------- T15
    /// T15: the governor cannot sweep an active deal's principal — sweepUnaccounted subtracts
    ///     `outstanding` first (D12/I20). Also, a non-governor caller cannot sweep at all.
    function test_T15_governorCannotSweepActiveDealPrincipal() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 deal = _openWith(keccak256("t15"), dl, _one(alice));

        // Non-governor sweep is rejected outright.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NotGovernor.selector, stranger));
        escrow.sweepUnaccounted(ESCROW_APP, deal, stranger);

        // Governor sweep of an active deal with no surplus removes nothing (principal is safe).
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NothingToSweep.selector, ESCROW_APP, deal));
        escrow.sweepUnaccounted(ESCROW_APP, deal, stranger);

        assertGe(ledger.balanceOf(ESCROW_APP, deal), escrow.outstanding(ESCROW_APP, deal));
    }
}

/// @notice T7 / T10 — threats needing a callback/blocklist-capable token. Uses {EvilUSDC}.
contract EscrowThreatsTokenTest is EscrowTestBase {
    EvilUSDC internal evil;
    MockSettlementCondition internal cond;
    ReentrantRecipient internal attacker;
    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        evil = new EvilUSDC();
        _setUpCore(address(evil));
        cond = new MockSettlementCondition();
        attacker = new ReentrantRecipient(escrow);
    }

    // ----------------------------------------------------------------- T7
    /// T7: reentrancy through the token/recipient cannot double-pay. Real USDC has no transfer
    ///     hook (D1); EvilUSDC adds one to stress the escrow's CEI (I14) + nonReentrant (I15)
    ///     defence-in-depth. The reentrant claim is rejected, so the attacker is paid once.
    function test_T7_reentrancyThroughRecipientCannotDrain() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 salt = keccak256("t7");
        bytes32 deal = _dealId(payer, salt, address(cond), AMOUNT, dl);
        ledger.credit(ESCROW_APP, deal, AMOUNT, keccak256("gw-t7"));
        cond.setOutcome(true, _one(address(attacker)), _amt1(AMOUNT));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, salt, address(cond), AMOUNT, dl, _one(address(attacker)));
        escrow.resolve(deal);

        attacker.arm(deal);
        evil.setReentrantHook(address(attacker));

        attacker.claim();
        assertTrue(attacker.reentered());
        assertEq(evil.balanceOf(address(attacker)), AMOUNT); // exactly one payout, not two
        assertEq(ledger.balanceOf(ESCROW_APP, deal), 0);
    }

    // ----------------------------------------------------------------- T10
    /// T10: a recipient that cannot receive (USDC-blocklisted / reverting) must not wedge the
    ///     whole deal. Per-recipient pull (D2) isolates the failure: the good recipient claims
    ///     successfully even though the blocked one cannot.
    function test_T10_blockedRecipientDoesNotWedgeOtherClaims() public {
        uint256 dl = block.timestamp + 1 days;
        bytes32 salt = keccak256("t10");
        bytes32 deal = _dealId(payer, salt, address(cond), AMOUNT, dl);
        ledger.credit(ESCROW_APP, deal, AMOUNT, keccak256("gw-t10"));
        cond.setOutcome(true, _two(alice, bob), _amt2(60e6, 40e6));
        vm.prank(governor);
        condReg.setApproved(address(cond), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, salt, address(cond), AMOUNT, dl, _two(alice, bob));
        escrow.resolve(deal);

        // bob is blocklisted by the token.
        evil.setBlocked(bob, true);

        // alice's claim still succeeds — she is not blocked by bob's inability to receive.
        vm.prank(alice);
        escrow.claim(deal);
        assertEq(evil.balanceOf(alice), 60e6);
        assertTrue(escrow.claimedOf(deal, alice));

        // bob's own claim reverts at the token transfer, harming only bob.
        vm.prank(bob);
        vm.expectRevert(bytes("USDC: recipient blocked"));
        escrow.claim(deal);
    }
}
