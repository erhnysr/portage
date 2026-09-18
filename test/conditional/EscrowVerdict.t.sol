// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {EscrowTestBase} from "./EscrowTestBase.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";
import {VerdictCondition} from "../../contracts/conditions/VerdictCondition.sol";
import {Arena} from "../../contracts/arena/Arena.sol";
import {ArenaFactory} from "../../contracts/arena/ArenaFactory.sol";
import {ReputationNFT} from "../../contracts/arena/ReputationNFT.sol";

/// @notice Tests for VerdictCondition against the REAL Coliseum Arena (contracts/arena/, not a mock). The
///         arena is deployed directly with the escrow's MockUSDC (the factory hardcodes USDC to the
///         Arc native address 0x3600…, unavailable locally) and authorized on the real
///         ReputationNFT via the factory, so finalize()'s repNFT.mint succeeds.
///
///         Exercises open → initialize → run arena → finalize → resolve → claim, plus the T9 race:
///         a phase-Ended-but-not-finalized arena must NOT settle.
///
/// @dev New file; extends {EscrowTestBase} and touches nothing else. Arena and the escrow deal use
///      the same MockUSDC instance, but the arena's own pot (submission fees) is never touched by
///      the condition — it reads winners only and pays the escrow principal (D8/§7).
contract EscrowVerdictTest is EscrowTestBase {
    VerdictCondition internal vc;
    ReputationNFT internal repNFT;
    ArenaFactory internal factory;

    uint256 internal constant AMOUNT = 100e6;

    function setUp() public override {
        super.setUp();
        repNFT = new ReputationNFT(address(this));
        factory = new ArenaFactory(address(repNFT));
        repNFT.setFactory(address(factory));
        vc = new VerdictCondition(address(escrow));
    }

    function _arr3(address a, address b, address c) internal pure returns (address[] memory arr) {
        arr = new address[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    /// @dev Deploy a real Arena with the escrow's USDC, authorize it on the real ReputationNFT
    ///      (via the factory), and have each submitter submit (0 votes → winners ranked by ID).
    function _arena(address[] memory submitters) internal returns (Arena arena, uint256 voteDl) {
        uint256 subDl = block.timestamp + 1 days;
        voteDl = block.timestamp + 2 days;
        arena = new Arena(address(this), address(usdc), address(repNFT), "topic", subDl, voteDl);
        vm.prank(address(factory));
        repNFT.authorizeArena(address(arena));
        for (uint256 i = 0; i < submitters.length; i++) {
            usdc.mint(submitters[i], arena.SUBMISSION_FEE());
            vm.startPrank(submitters[i]);
            usdc.approve(address(arena), type(uint256).max);
            arena.submit("ref");
            vm.stopPrank();
        }
    }

    /// @dev Fund + approve the condition + open a deal bound to VerdictCondition.
    function _open(bytes32 salt, address[] memory participants, uint256 amount, uint256 hardDl)
        internal
        returns (bytes32 deal)
    {
        deal = _dealId(payer, salt, address(vc), amount, hardDl);
        _fund(deal, amount);
        vm.prank(governor);
        condReg.setApproved(address(vc), true);
        vm.prank(payer);
        escrow.open(ESCROW_APP, deal, payer, salt, address(vc), amount, hardDl, participants);
    }

    // ----------------------------------------------------------------- count == 1 → 1st ~100%
    function test_count1_firstTakesAll() public {
        uint256 hardDl = block.timestamp + 30 days;
        (Arena arena, uint256 voteDl) = _arena(_one(alice));
        bytes32 deal = _open(keccak256("c1"), _one(alice), AMOUNT, hardDl);
        vm.prank(payer);
        vc.initialize(deal, address(arena));

        vm.warp(voteDl);
        arena.finalize();

        escrow.resolve(deal);
        (address[] memory r, uint256[] memory a) = escrow.allocationOf(deal);
        assertEq(r.length, 1);
        assertEq(r[0], alice);
        assertEq(a[0], AMOUNT); // 60 + 30 + 10 collapse to 1st

        vm.prank(alice);
        escrow.claim(deal);
        assertEq(usdc.balanceOf(alice), AMOUNT); // minted fee spent on submit, then claimed AMOUNT
    }

    // ----------------------------------------------------------------- count == 2 → 70 / 30
    function test_count2_seventyThirty() public {
        uint256 hardDl = block.timestamp + 30 days;
        (Arena arena, uint256 voteDl) = _arena(_two(alice, bob));
        bytes32 deal = _open(keccak256("c2"), _two(alice, bob), AMOUNT, hardDl);
        vm.prank(payer);
        vc.initialize(deal, address(arena));

        vm.warp(voteDl);
        arena.finalize();
        escrow.resolve(deal);

        (address[] memory r, uint256[] memory a) = escrow.allocationOf(deal);
        assertEq(r.length, 2);
        assertEq(r[0], alice);
        assertEq(a[0], 70e6); // 60 + collapsed 3rd(10)
        assertEq(r[1], bob);
        assertEq(a[1], 30e6);

        vm.prank(alice);
        escrow.claim(deal);
        vm.prank(bob);
        escrow.claim(deal);
        assertEq(usdc.balanceOf(alice), 70e6);
        assertEq(usdc.balanceOf(bob), 30e6);
    }

    // ----------------------------------------------------------------- count == 3 → 60 / 30 / 10
    function test_count3_sixtyThirtyTen_sumsExact() public {
        uint256 hardDl = block.timestamp + 30 days;
        (Arena arena, uint256 voteDl) = _arena(_arr3(alice, bob, carol));
        bytes32 deal = _open(keccak256("c3"), _arr3(alice, bob, carol), AMOUNT, hardDl);
        vm.prank(payer);
        vc.initialize(deal, address(arena));

        vm.warp(voteDl);
        arena.finalize();
        escrow.resolve(deal);

        (address[] memory r, uint256[] memory a) = escrow.allocationOf(deal);
        assertEq(r.length, 3);
        assertEq(r[0], alice);
        assertEq(a[0], 60e6);
        assertEq(r[1], bob);
        assertEq(a[1], 30e6);
        assertEq(r[2], carol);
        assertEq(a[2], 10e6);
        assertEq(a[0] + a[1] + a[2], AMOUNT); // Σ == deal.amount exactly (I2)

        vm.prank(alice);
        escrow.claim(deal);
        vm.prank(bob);
        escrow.claim(deal);
        vm.prank(carol);
        escrow.claim(deal);
        assertEq(usdc.balanceOf(alice), 60e6);
        assertEq(usdc.balanceOf(bob), 30e6);
        assertEq(usdc.balanceOf(carol), 10e6);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Claimed));
    }

    // ----------------------------------------------------------------- rounding dust → 1st
    /// A non-divisible amount leaves 1 atomic unit of dust after flooring; it is added to 1st.
    function test_dustGoesToFirstPlace() public {
        uint256 amount = 100e6 + 1; // 100000001: 60%/30%/10% floors sum to 100000000, dust = 1
        uint256 hardDl = block.timestamp + 30 days;
        (Arena arena, uint256 voteDl) = _arena(_arr3(alice, bob, carol));
        bytes32 deal = _open(keccak256("dust"), _arr3(alice, bob, carol), amount, hardDl);
        vm.prank(payer);
        vc.initialize(deal, address(arena));

        vm.warp(voteDl);
        arena.finalize();
        escrow.resolve(deal);

        (, uint256[] memory a) = escrow.allocationOf(deal);
        assertEq(a[0], 60_000_001); // 60000000 + 1 dust
        assertEq(a[1], 30_000_000);
        assertEq(a[2], 10_000_000);
        assertEq(a[0] + a[1] + a[2], amount);
    }

    // ----------------------------------------------------------------- no winner → permanent fail-closed
    function test_noWinner_neverSettles_thenRefund() public {
        uint256 hardDl = block.timestamp + 30 days;
        address[] memory none = new address[](0);
        (Arena arena, uint256 voteDl) = _arena(none); // zero submissions
        bytes32 deal = _open(keccak256("empty"), _one(alice), AMOUNT, hardDl);
        vm.prank(payer);
        vc.initialize(deal, address(arena));

        vm.warp(voteDl);
        arena.finalize(); // count == 0 → winners stay [0,0,0]

        (bool settled,,) = vc.resolve(deal);
        assertFalse(settled, "no winner -> not settled");
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NotSettled.selector, deal));
        escrow.resolve(deal);

        // Falls through to the escrow hard-deadline refund.
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.warp(hardDl + 1);
        vm.prank(payer);
        escrow.refund(deal);
        assertEq(uint8(escrow.stateOf(deal)), uint8(IConditionalEscrow.State.Refunded));
        assertEq(usdc.balanceOf(payer), payerBefore + AMOUNT);
    }

    // ----------------------------------------------------------------- T9: phase Ended but not finalized
    /// The core T9 test: after votingDeadline the arena's getPhase() is Ended, yet finalized() is
    /// still false until someone calls finalize(). VerdictCondition reads finalized() (never
    /// getPhase()), so it must NOT settle in that window — and does settle once finalized.
    function test_T9_phaseEndedButNotFinalized_doesNotSettle() public {
        uint256 hardDl = block.timestamp + 30 days;
        (Arena arena, uint256 voteDl) = _arena(_one(alice));
        bytes32 deal = _open(keccak256("t9"), _one(alice), AMOUNT, hardDl);
        vm.prank(payer);
        vc.initialize(deal, address(arena));

        vm.warp(voteDl); // voting window closed → phase Ended, but nobody has finalized yet

        assertEq(uint8(arena.getPhase()), uint8(Arena.Phase.Ended), "phase is Ended");
        assertFalse(arena.finalized(), "but not finalized");

        (bool settledPre,,) = vc.resolve(deal);
        assertFalse(settledPre, "T9: Ended-not-finalized must NOT settle");
        vm.expectRevert(abi.encodeWithSelector(IConditionalEscrow.NotSettled.selector, deal));
        escrow.resolve(deal);

        // Once the verdict is actually recorded, it settles.
        arena.finalize();
        (bool settledPost,,) = vc.resolve(deal);
        assertTrue(settledPost, "settles after finalize()");
        escrow.resolve(deal);
        vm.prank(alice);
        escrow.claim(deal);
        assertEq(usdc.balanceOf(alice), AMOUNT);
    }

    // ----------------------------------------------------------------- initialize guards
    function test_initialize_onlyPayer() public {
        uint256 hardDl = block.timestamp + 30 days;
        (Arena arena,) = _arena(_one(alice));
        bytes32 deal = _open(keccak256("initauth"), _one(alice), AMOUNT, hardDl);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(VerdictCondition.NotPayer.selector, deal, stranger));
        vc.initialize(deal, address(arena));
    }

    function test_initialize_zeroArenaReverts() public {
        uint256 hardDl = block.timestamp + 30 days;
        bytes32 deal = _open(keccak256("zero"), _one(alice), AMOUNT, hardDl);
        vm.prank(payer);
        vm.expectRevert(VerdictCondition.ZeroAddress.selector);
        vc.initialize(deal, address(0));
    }

    function test_initialize_alreadyInitializedReverts() public {
        uint256 hardDl = block.timestamp + 30 days;
        (Arena arena,) = _arena(_one(alice));
        bytes32 deal = _open(keccak256("dup"), _one(alice), AMOUNT, hardDl);
        vm.prank(payer);
        vc.initialize(deal, address(arena));
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(VerdictCondition.AlreadyInitialized.selector, deal));
        vc.initialize(deal, address(arena));
    }
}
