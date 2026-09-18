// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {EscrowTestBase} from "./EscrowTestBase.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";
import {TimelockCondition} from "../../contracts/conditions/TimelockCondition.sol";

/// @notice Tests for TimelockCondition — "resolves when a soft deadline passes with no objection."
///         Runs against REAL Portage core + escrow (the condition reads the escrow's public views),
///         so this also exercises the open → initialize → (wait) → resolve → claim path, plus the
///         object → hard-deadline refund fallback.
///
/// @dev New file; extends {EscrowTestBase} and touches nothing else.
contract EscrowTimelockTest is EscrowTestBase {
    TimelockCondition internal tlc;

    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        super.setUp();
        tlc = new TimelockCondition(address(escrow));
    }

    /// @dev Fund + approve + open a Funded deal against the TimelockCondition. hardDeadline is far
    ///      out so a soft deadline can sit strictly before it.
    function _open(bytes32 salt, address[] memory participants) internal returns (bytes32 deal, uint256 hardDl) {
        hardDl = block.timestamp + 365 days;
        deal = _dealId(payer, salt, address(tlc), AMOUNT, hardDl);
        _fund(deal, AMOUNT);
        vm.prank(governor);
        condReg.setApproved(address(tlc), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, salt, address(tlc), AMOUNT, hardDl, participants);
    }

    // ----------------------------------------------------------------- init: only payer, once
    function test_initialize_onlyPayerOnce() public {
        (bytes32 deal,) = _open(keccak256("init"), _two(alice, bob));
        uint64 soft = uint64(block.timestamp + 7 days);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(TimelockCondition.NotPayer.selector, deal, stranger));
        tlc.initialize(deal, soft, _two(alice, bob), _amt2(60e6, 40e6));

        vm.prank(payer);
        tlc.initialize(deal, soft, _two(alice, bob), _amt2(60e6, 40e6));
        assertTrue(tlc.isInitialized(deal));
        assertEq(tlc.softDeadlineOf(deal), soft);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(TimelockCondition.AlreadyInitialized.selector, deal));
        tlc.initialize(deal, soft, _two(alice, bob), _amt2(60e6, 40e6));
    }

    // ----------------------------------------------------------------- init: soft >= hard reverts
    function test_initialize_softDeadlineNotBeforeHardReverts() public {
        (bytes32 deal, uint256 hardDl) = _open(keccak256("soft"), _two(alice, bob));

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockCondition.SoftDeadlineNotBeforeHard.selector, uint64(hardDl), hardDl)
        );
        tlc.initialize(deal, uint64(hardDl), _two(alice, bob), _amt2(60e6, 40e6)); // soft == hard
    }

    // ----------------------------------------------------------------- resolve before soft deadline
    function test_resolve_falseBeforeSoftDeadline() public {
        (bytes32 deal,) = _open(keccak256("early"), _two(alice, bob));
        uint64 soft = uint64(block.timestamp + 7 days);
        vm.prank(payer);
        tlc.initialize(deal, soft, _two(alice, bob), _amt2(60e6, 40e6));

        (bool settled,,) = tlc.resolve(deal);
        assertFalse(settled, "not settled before soft deadline");

        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NotSettled.selector, deal));
        escrow.resolve(deal);
    }

    // ----------------------------------------------------------------- happy: timeout with no objection
    function test_resolve_trueAfterSoftDeadline_thenClaim() public {
        (bytes32 deal,) = _open(keccak256("timeout"), _two(alice, bob));
        uint64 soft = uint64(block.timestamp + 7 days);
        vm.prank(payer);
        tlc.initialize(deal, soft, _two(alice, bob), _amt2(60e6, 40e6));

        vm.warp(soft); // >= soft deadline, no objection
        (bool settled, address[] memory r, uint256[] memory a) = tlc.resolve(deal);
        assertTrue(settled);
        assertEq(r[0], alice);
        assertEq(a[0], 60e6);
        assertEq(r[1], bob);
        assertEq(a[1], 40e6);

        escrow.resolve(deal);
        vm.prank(alice);
        escrow.claim(deal);
        vm.prank(bob);
        escrow.claim(deal);
        assertEq(usdc.balanceOf(alice), 60e6);
        assertEq(usdc.balanceOf(bob), 40e6);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Claimed));
    }

    // ----------------------------------------------------------------- object: permanent block
    function test_object_permanentlyBlocksResolveThenRefund() public {
        (bytes32 deal, uint256 hardDl) = _open(keccak256("object"), _two(alice, bob));
        uint64 soft = uint64(block.timestamp + 7 days);
        vm.prank(payer);
        tlc.initialize(deal, soft, _two(alice, bob), _amt2(60e6, 40e6));

        vm.prank(payer);
        tlc.object(deal);
        assertTrue(tlc.isObjected(deal));

        // Even past the soft deadline the condition never resolves.
        vm.warp(soft + 1);
        (bool settled,,) = tlc.resolve(deal);
        assertFalse(settled, "objection is permanent");
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NotSettled.selector, deal));
        escrow.resolve(deal);

        // Falls through to the escrow's hard-deadline refund.
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.warp(hardDl + 1);
        vm.prank(payer);
        escrow.refund(deal);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Refunded));
        assertEq(usdc.balanceOf(payer), payerBefore + AMOUNT);
    }

    // ----------------------------------------------------------------- object: only payer
    function test_object_onlyPayerReverts() public {
        (bytes32 deal,) = _open(keccak256("objauth"), _two(alice, bob));
        uint64 soft = uint64(block.timestamp + 7 days);
        vm.prank(payer);
        tlc.initialize(deal, soft, _two(alice, bob), _amt2(60e6, 40e6));

        vm.prank(alice); // a participant, but not the payer
        vm.expectRevert(abi.encodeWithSelector(TimelockCondition.NotPayer.selector, deal, alice));
        tlc.object(deal);
    }

    // ----------------------------------------------------------------- object: twice reverts
    function test_object_twiceReverts() public {
        (bytes32 deal,) = _open(keccak256("obj2"), _two(alice, bob));
        uint64 soft = uint64(block.timestamp + 7 days);
        vm.prank(payer);
        tlc.initialize(deal, soft, _two(alice, bob), _amt2(60e6, 40e6));

        vm.prank(payer);
        tlc.object(deal);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(TimelockCondition.AlreadyObjected.selector, deal));
        tlc.object(deal);
    }

    // ----------------------------------------------------------------- init allocation validation
    function test_initialize_recipientNotParticipantReverts() public {
        (bytes32 deal,) = _open(keccak256("foreign"), _one(alice));
        uint64 soft = uint64(block.timestamp + 7 days);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockCondition.RecipientNotParticipant.selector, deal, stranger)
        );
        tlc.initialize(deal, soft, _one(stranger), _amt1(AMOUNT));
    }

    function test_initialize_sumMismatchReverts() public {
        (bytes32 deal,) = _open(keccak256("sum"), _two(alice, bob));
        uint64 soft = uint64(block.timestamp + 7 days);
        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockCondition.AllocationSumMismatch.selector, deal, 90e6, AMOUNT)
        );
        tlc.initialize(deal, soft, _two(alice, bob), _amt2(60e6, 30e6)); // 90 != 100
    }
}
