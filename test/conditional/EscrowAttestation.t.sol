// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {EscrowTestBase} from "./EscrowTestBase.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";
import {AttestationCondition} from "../../contracts/conditions/AttestationCondition.sol";

/// @notice Tests for AttestationCondition — "a designated attester signs off." Runs against REAL
///         Portage core + escrow (the condition reads the escrow's public views), exercising the
///         open → initialize → attest → resolve → claim path.
///
/// @dev New file; extends {EscrowTestBase} and touches nothing else.
contract EscrowAttestationTest is EscrowTestBase {
    AttestationCondition internal aac;
    address internal attester = makeAddr("attester");

    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        super.setUp();
        aac = new AttestationCondition(address(escrow));
    }

    function _open(bytes32 salt, address[] memory participants) internal returns (bytes32 deal) {
        uint256 dl = block.timestamp + 365 days;
        deal = _dealId(payer, salt, address(aac), AMOUNT, dl);
        _fund(deal, AMOUNT);
        vm.prank(governor);
        condReg.setApproved(address(aac), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, salt, address(aac), AMOUNT, dl, participants);
    }

    // ----------------------------------------------------------------- init: payer-only, once, non-zero
    function test_initialize_onlyPayerOnce_zeroAttesterReverts() public {
        bytes32 deal = _open(keccak256("init"), _two(alice, bob));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AttestationCondition.NotPayer.selector, deal, stranger));
        aac.initialize(deal, attester);

        vm.prank(payer);
        vm.expectRevert(AttestationCondition.ZeroAddress.selector);
        aac.initialize(deal, address(0));

        vm.prank(payer);
        aac.initialize(deal, attester);
        assertTrue(aac.isInitialized(deal));
        assertEq(aac.attesterOf(deal), attester);

        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(AttestationCondition.AlreadyInitialized.selector, deal));
        aac.initialize(deal, attester);
    }

    // ----------------------------------------------------------------- attest: only designated attester
    function test_attest_onlyDesignatedAttester() public {
        bytes32 deal = _open(keccak256("auth"), _two(alice, bob));
        vm.prank(payer);
        aac.initialize(deal, attester);

        // Neither the payer nor a participant nor a stranger may attest.
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(AttestationCondition.NotAttester.selector, deal, payer));
        aac.attest(deal, _two(alice, bob), _amt2(60e6, 40e6));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AttestationCondition.NotAttester.selector, deal, alice));
        aac.attest(deal, _two(alice, bob), _amt2(60e6, 40e6));

        vm.prank(attester);
        aac.attest(deal, _two(alice, bob), _amt2(60e6, 40e6));
        assertTrue(aac.isAttested(deal));
    }

    // ----------------------------------------------------------------- attest twice reverts
    function test_attest_twiceReverts() public {
        bytes32 deal = _open(keccak256("twice"), _two(alice, bob));
        vm.prank(payer);
        aac.initialize(deal, attester);

        vm.prank(attester);
        aac.attest(deal, _two(alice, bob), _amt2(60e6, 40e6));

        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(AttestationCondition.AlreadyAttested.selector, deal));
        aac.attest(deal, _two(alice, bob), _amt2(50e6, 50e6));
    }

    // ----------------------------------------------------------------- attest before initialize reverts
    function test_attest_beforeInitializeReverts() public {
        bytes32 deal = _open(keccak256("noinit"), _two(alice, bob));
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(AttestationCondition.NotInitialized.selector, deal));
        aac.attest(deal, _two(alice, bob), _amt2(60e6, 40e6));
    }

    // ----------------------------------------------------------------- resolve before/after attest
    function test_resolve_falseBeforeAttest() public {
        bytes32 deal = _open(keccak256("pre"), _two(alice, bob));
        vm.prank(payer);
        aac.initialize(deal, attester);

        (bool settled,,) = aac.resolve(deal);
        assertFalse(settled);

        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NotSettled.selector, deal));
        escrow.resolve(deal);
    }

    function test_resolve_trueAfterAttest_thenClaim() public {
        bytes32 deal = _open(keccak256("post"), _two(alice, bob));
        vm.prank(payer);
        aac.initialize(deal, attester);
        vm.prank(attester);
        aac.attest(deal, _two(alice, bob), _amt2(60e6, 40e6));

        (bool settled, address[] memory r, uint256[] memory a) = aac.resolve(deal);
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

    // ----------------------------------------------------------------- attest allocation validation
    function test_attest_recipientNotParticipantReverts() public {
        bytes32 deal = _open(keccak256("foreign"), _one(alice));
        vm.prank(payer);
        aac.initialize(deal, attester);

        vm.prank(attester);
        vm.expectRevert(
            abi.encodeWithSelector(AttestationCondition.RecipientNotParticipant.selector, deal, stranger)
        );
        aac.attest(deal, _one(stranger), _amt1(AMOUNT));
    }

    function test_attest_sumMismatchReverts() public {
        bytes32 deal = _open(keccak256("sum"), _two(alice, bob));
        vm.prank(payer);
        aac.initialize(deal, attester);

        vm.prank(attester);
        vm.expectRevert(
            abi.encodeWithSelector(AttestationCondition.AllocationSumMismatch.selector, deal, 90e6, AMOUNT)
        );
        aac.attest(deal, _two(alice, bob), _amt2(60e6, 30e6)); // 90 != 100
    }
}
