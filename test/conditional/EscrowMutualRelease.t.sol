// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {EscrowTestBase} from "./EscrowTestBase.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";
import {MutualReleaseCondition} from "../../contracts/conditions/MutualReleaseCondition.sol";

/// @notice Tests for MutualReleaseCondition — the "both parties sign off" settlement condition.
///         Party set = payer + participants (read from the escrow); each approves an identical
///         allocation (count-per-hash), and unanimity finalizes. Runs against REAL Portage core +
///         escrow (the condition reads the escrow's public views to authenticate parties), so this
///         also exercises the full open → approve×N → resolve → claim path end to end.
///
/// @dev New file; extends {EscrowTestBase} and touches nothing else.
contract EscrowMutualReleaseTest is EscrowTestBase {
    MutualReleaseCondition internal mrc;

    uint256 internal constant AMOUNT = 100e6;

    // Local mirrors of the condition's events, for vm.expectEmit.
    event AllocationApproved(bytes32 indexed dealId, address indexed party, bytes32 indexed allocationHash);
    event AllocationFinalized(bytes32 indexed dealId, bytes32 allocationHash);

    function setUp() public override {
        super.setUp();
        mrc = new MutualReleaseCondition(address(escrow));
    }

    /// @dev Fund + approve the condition + open a Funded deal against the MutualReleaseCondition.
    function _open(bytes32 salt, address[] memory participants) internal returns (bytes32 deal) {
        uint256 dl = block.timestamp + 365 days;
        deal = _dealId(payer, salt, address(mrc), AMOUNT, dl);
        _fund(deal, AMOUNT);
        vm.prank(governor);
        condReg.setApproved(address(mrc), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, salt, address(mrc), AMOUNT, dl, participants);
    }

    function _hash(address[] memory r, uint256[] memory a) internal pure returns (bytes32) {
        return keccak256(abi.encode(r, a));
    }

    // ----------------------------------------------------------------- happy path
    /// All parties (alice, bob, payer) approve the same split; it finalizes, the escrow resolves to
    /// that allocation, and each recipient claims their share.
    function test_happyPath_unanimousApprove_resolve_claim() public {
        bytes32 deal = _open(keccak256("happy"), _two(alice, bob));
        address[] memory r = _two(alice, bob);
        uint256[] memory a = _amt2(60e6, 40e6);

        vm.prank(alice);
        mrc.approve(deal, r, a);
        assertFalse(mrc.finalized(deal), "not final after 1");
        vm.prank(bob);
        mrc.approve(deal, r, a);
        assertFalse(mrc.finalized(deal), "not final after 2");
        vm.prank(payer);
        mrc.approve(deal, r, a); // payer completes the quorum (3 of 3)
        assertTrue(mrc.finalized(deal), "final after payer");

        // Escrow reads the condition once and snapshots (D5).
        escrow.resolve(deal);
        (address[] memory rr, uint256[] memory aa) = escrow.allocationOf(deal);
        assertEq(rr.length, 2);
        assertEq(rr[0], alice);
        assertEq(aa[0], 60e6);
        assertEq(rr[1], bob);
        assertEq(aa[1], 40e6);

        vm.prank(alice);
        escrow.claim(deal);
        vm.prank(bob);
        escrow.claim(deal);
        assertEq(usdc.balanceOf(alice), 60e6);
        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Claimed));
    }

    // ----------------------------------------------------------------- resolve before unanimity
    /// Without every party approving, the condition reports settled=false and escrow.resolve reverts.
    function test_resolve_revertsBeforeUnanimity() public {
        bytes32 deal = _open(keccak256("partial"), _two(alice, bob));
        address[] memory r = _two(alice, bob);
        uint256[] memory a = _amt2(60e6, 40e6);

        vm.prank(alice);
        mrc.approve(deal, r, a);
        vm.prank(bob);
        mrc.approve(deal, r, a);
        // payer has NOT approved → not unanimous.

        assertFalse(mrc.finalized(deal));
        (bool settled,,) = mrc.resolve(deal);
        assertFalse(settled, "condition not settled");

        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NotSettled.selector, deal));
        escrow.resolve(deal);
    }

    // ----------------------------------------------------------------- auth
    /// A non-payer, non-participant cannot approve.
    function test_approve_unauthorizedReverts() public {
        bytes32 deal = _open(keccak256("auth"), _two(alice, bob));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MutualReleaseCondition.NotDealParty.selector, deal, stranger));
        mrc.approve(deal, _two(alice, bob), _amt2(60e6, 40e6));
    }

    // ----------------------------------------------------------------- deal not open (never opened)
    /// Approving a dealId that was never opened reverts (state == None).
    function test_approve_beforeOpenReverts() public {
        uint256 dl = block.timestamp + 365 days;
        bytes32 deal = _dealId(payer, keccak256("unopened"), address(mrc), AMOUNT, dl);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                MutualReleaseCondition.DealNotOpen.selector, deal, IConditionalEscrow.State.None
            )
        );
        mrc.approve(deal, _one(alice), _amt1(AMOUNT));
    }

    // ----------------------------------------------------------------- deal not open (refunded)
    /// After the deal is refunded, approvals are rejected with the refunded state.
    function test_approve_afterRefundReverts() public {
        uint256 dl = block.timestamp + 365 days;
        bytes32 deal = _dealId(payer, keccak256("refunded"), address(mrc), AMOUNT, dl);
        _fund(deal, AMOUNT);
        vm.prank(governor);
        condReg.setApproved(address(mrc), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, keccak256("refunded"), address(mrc), AMOUNT, dl, _two(alice, bob));

        vm.warp(dl + 1);
        vm.prank(payer);
        escrow.refund(deal); // state -> Refunded

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                MutualReleaseCondition.DealNotOpen.selector, deal, IConditionalEscrow.State.Refunded
            )
        );
        mrc.approve(deal, _two(alice, bob), _amt2(60e6, 40e6));
    }

    // ----------------------------------------------------------------- already finalized
    /// Once unanimous, further approvals revert AlreadyFinalized (even before escrow.resolve).
    function test_approve_afterFinalizedReverts() public {
        bytes32 deal = _open(keccak256("final"), _two(alice, bob));
        address[] memory r = _two(alice, bob);
        uint256[] memory a = _amt2(60e6, 40e6);
        vm.prank(alice);
        mrc.approve(deal, r, a);
        vm.prank(bob);
        mrc.approve(deal, r, a);
        vm.prank(payer);
        mrc.approve(deal, r, a);
        assertTrue(mrc.finalized(deal));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MutualReleaseCondition.AlreadyFinalized.selector, deal));
        mrc.approve(deal, r, a);
    }

    // ----------------------------------------------------------------- allocation validation
    /// A recipient outside the participant set is rejected (T1 defense-in-depth).
    function test_approve_recipientNotParticipantReverts() public {
        bytes32 deal = _open(keccak256("foreign"), _one(alice));
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(MutualReleaseCondition.RecipientNotParticipant.selector, deal, stranger)
        );
        mrc.approve(deal, _one(stranger), _amt1(AMOUNT));
    }

    /// Amounts not summing to the deal amount are rejected (I2 defense-in-depth).
    function test_approve_sumMismatchReverts() public {
        bytes32 deal = _open(keccak256("sum"), _two(alice, bob));
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(MutualReleaseCondition.AllocationSumMismatch.selector, deal, 90e6, AMOUNT)
        );
        mrc.approve(deal, _two(alice, bob), _amt2(60e6, 30e6)); // 90 != 100
    }

    /// Empty and length-mismatched allocations are rejected.
    function test_approve_emptyAndLengthMismatchRevert() public {
        bytes32 deal = _open(keccak256("shape"), _two(alice, bob));

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(MutualReleaseCondition.EmptyAllocation.selector, deal));
        mrc.approve(deal, new address[](0), new uint256[](0));

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(MutualReleaseCondition.AllocationLengthMismatch.selector, 2, 1));
        mrc.approve(deal, _two(alice, bob), _amt1(AMOUNT));
    }

    // ----------------------------------------------------------------- count-per-hash / renegotiation
    /// Distinct allocation hashes tally independently; only a hash approved by ALL parties
    /// finalizes. A floated alternative does not reset an existing near-consensus.
    function test_countPerHash_onlyUnanimousHashFinalizes() public {
        bytes32 deal = _open(keccak256("nego"), _two(alice, bob));
        address[] memory r = _two(alice, bob);
        uint256[] memory h1 = _amt2(60e6, 40e6);
        uint256[] memory h2 = _amt2(50e6, 50e6);

        vm.prank(alice);
        mrc.approve(deal, r, h1); // h1: {alice}
        vm.prank(payer);
        mrc.approve(deal, r, h2); // h2: {payer}
        vm.prank(bob);
        mrc.approve(deal, r, h1); // h1: {alice, bob}
        assertFalse(mrc.finalized(deal), "no hash has all 3 yet");
        assertEq(mrc.approvalCount(deal, _hash(r, h1)), 2);
        assertEq(mrc.approvalCount(deal, _hash(r, h2)), 1);

        vm.prank(payer);
        mrc.approve(deal, r, h1); // h1: {alice, bob, payer} -> finalize
        assertTrue(mrc.finalized(deal));
        escrow.resolve(deal);
        (, uint256[] memory aa) = escrow.allocationOf(deal);
        assertEq(aa[0], 60e6);
        assertEq(aa[1], 40e6);
    }

    /// A repeat approval by the same party on the same hash does not double-count.
    function test_duplicateApprovalDoesNotDoubleCount() public {
        bytes32 deal = _open(keccak256("dup"), _two(alice, bob));
        address[] memory r = _two(alice, bob);
        uint256[] memory a = _amt2(60e6, 40e6);

        vm.prank(alice);
        mrc.approve(deal, r, a);
        vm.prank(alice);
        mrc.approve(deal, r, a); // duplicate — no-op on the tally
        assertEq(mrc.approvalCount(deal, _hash(r, a)), 1, "alice counted once");
        assertFalse(mrc.finalized(deal));
    }

    /// Payer that is also a participant is de-duplicated in the quorum (required == 2, not 3).
    function test_payerAsParticipant_dedupedQuorum() public {
        bytes32 deal = _open(keccak256("payerpart"), _two(payer, alice));
        address[] memory r = _one(alice);
        uint256[] memory a = _amt1(AMOUNT);

        vm.prank(payer);
        mrc.approve(deal, r, a); // {payer}
        assertFalse(mrc.finalized(deal));
        vm.prank(alice);
        mrc.approve(deal, r, a); // {payer, alice} == required(2) -> finalize
        assertTrue(mrc.finalized(deal), "deduped quorum of 2 reached");
    }

    // ----------------------------------------------------------------- events
    /// AllocationApproved fires per distinct approval; AllocationFinalized fires on unanimity.
    function test_events_approvedAndFinalized() public {
        bytes32 deal = _open(keccak256("event"), _two(alice, bob));
        address[] memory r = _two(alice, bob);
        uint256[] memory a = _amt2(60e6, 40e6);
        bytes32 h = _hash(r, a);

        vm.expectEmit(true, true, true, true, address(mrc));
        emit AllocationApproved(deal, alice, h);
        vm.prank(alice);
        mrc.approve(deal, r, a);

        vm.expectEmit(true, true, true, true, address(mrc));
        emit AllocationApproved(deal, bob, h);
        vm.prank(bob);
        mrc.approve(deal, r, a);

        // payer's approval emits AllocationApproved then AllocationFinalized.
        vm.expectEmit(true, false, false, true, address(mrc));
        emit AllocationFinalized(deal, h);
        vm.prank(payer);
        mrc.approve(deal, r, a);
    }
}
