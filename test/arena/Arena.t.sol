// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../contracts/arena/Arena.sol";
import "../../contracts/arena/ReputationNFT.sol";

/// @dev Minimal mock USDC (6 decimals) for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ArenaTest is Test {
    MockUSDC internal usdc;
    ReputationNFT internal repNFT;
    Arena internal arena;

    address internal owner = address(0x1);
    address internal factory = address(0x2);
    address internal creator = address(0x10);

    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal carol = address(0xC);

    uint256 internal constant SUBMISSION_FEE = 100_000;
    uint256 internal constant VOTE_STAKE = 50_000;
    uint256 internal constant PRIZE_POOL = 1_000_000; // 1 USDC

    uint256 internal subDeadline;
    uint256 internal voteDeadline;

    // Redeclared for vm.expectEmit (must match Arena.Voted exactly)
    event Voted(uint256 indexed submissionId, address indexed voter, string reason);

    function setUp() public {
        usdc = new MockUSDC();

        vm.prank(owner);
        repNFT = new ReputationNFT(owner);
        vm.prank(owner);
        repNFT.setFactory(factory);

        subDeadline = block.timestamp + 1 days;
        voteDeadline = block.timestamp + 2 days;

        // Deploy arena as factory
        vm.prank(factory);
        arena = new Arena(
            creator,
            address(usdc),
            address(repNFT),
            "Best Meme",
            subDeadline,
            voteDeadline
        );

        // Authorize this arena to mint NFTs (normally done by ArenaFactory)
        vm.prank(factory);
        repNFT.authorizeArena(address(arena));

        // Seed prize pool
        usdc.mint(address(arena), PRIZE_POOL);

        // Fund participants
        usdc.mint(alice, 10_000_000);
        usdc.mint(bob, 10_000_000);
        usdc.mint(carol, 10_000_000);
        usdc.mint(creator, 10_000_000);
    }

    // ── submit ────────────────────────────────────────────────────

    function test_submit_success() public {
        vm.prank(alice);
        usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice);
        arena.submit("ipfs://Qm1");

        assertEq(arena.getSubmissionCount(), 1);
        Arena.Submission memory s = arena.getSubmission(0);
        assertEq(s.submitter, alice);
        assertEq(s.contentRef, "ipfs://Qm1");
    }

    function test_submit_afterDeadline_reverts() public {
        vm.warp(subDeadline + 1);
        vm.prank(alice);
        usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice);
        vm.expectRevert("Arena: submission phase ended");
        arena.submit("ipfs://Qm1");
    }

    function test_submit_duplicate_reverts() public {
        vm.prank(alice);
        usdc.approve(address(arena), SUBMISSION_FEE * 2);
        vm.prank(alice);
        arena.submit("ipfs://Qm1");
        vm.prank(alice);
        vm.expectRevert("Arena: already submitted");
        arena.submit("ipfs://Qm2");
    }

    function test_submit_transfersFee() public {
        uint256 balBefore = usdc.balanceOf(address(arena));
        vm.prank(alice);
        usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice);
        arena.submit("ipfs://Qm1");
        assertEq(usdc.balanceOf(address(arena)), balBefore + SUBMISSION_FEE);
    }

    function test_submit_emptyContent_reverts() public {
        vm.prank(alice);
        usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice);
        vm.expectRevert("Arena: empty content ref");
        arena.submit("");
    }

    // ── vote ──────────────────────────────────────────────────────

    function _setupSubmissions() internal {
        vm.prank(alice);
        usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice);
        arena.submit("ipfs://A");

        vm.prank(bob);
        usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(bob);
        arena.submit("ipfs://B");

        vm.warp(subDeadline + 1); // enter voting phase
    }

    function test_vote_success() public {
        _setupSubmissions();
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(carol);
        arena.vote(0, "");

        assertTrue(arena.hasVotedInArena(carol));
        assertEq(arena.voterChoice(carol), 0);
        Arena.Submission memory s = arena.getSubmission(0);
        assertEq(s.votes, 1);
    }

    function test_vote_beforeVotingPhase_reverts() public {
        vm.prank(alice);
        usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice);
        arena.submit("ipfs://A");

        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(carol);
        vm.expectRevert("Arena: voting not started");
        arena.vote(0, "");
    }

    function test_vote_afterDeadline_reverts() public {
        _setupSubmissions();
        vm.warp(voteDeadline + 1);
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(carol);
        vm.expectRevert("Arena: voting phase ended");
        arena.vote(0, "");
    }

    function test_vote_twice_reverts() public {
        _setupSubmissions();
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE * 2);
        vm.prank(carol);
        arena.vote(0, "");
        vm.prank(carol);
        vm.expectRevert("Arena: already voted");
        arena.vote(1, "");
    }

    function test_vote_invalidSubmission_reverts() public {
        _setupSubmissions();
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(carol);
        vm.expectRevert("Arena: invalid submission");
        arena.vote(99, "");
    }

    function test_vote_emitsReason() public {
        _setupSubmissions();
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);

        vm.expectEmit(true, true, false, true, address(arena));
        emit Voted(0, carol, "clean concept, best execution");

        vm.prank(carol);
        arena.vote(0, "clean concept, best execution");
    }

    function test_vote_emptyReason_ok() public {
        _setupSubmissions();
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);

        vm.expectEmit(true, true, false, true, address(arena));
        emit Voted(0, carol, "");

        vm.prank(carol);
        arena.vote(0, ""); // empty reason is allowed

        assertEq(arena.voterChoice(carol), 0);
        assertEq(arena.getSubmission(0).votes, 1);
    }

    function test_vote_reasonTooLong_reverts() public {
        _setupSubmissions();
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);

        string memory tooLong = new string(281); // 281 bytes > MAX_REASON_LENGTH (280)
        vm.prank(carol);
        vm.expectRevert("Arena: reason too long");
        arena.vote(0, tooLong);
    }

    function test_vote_reasonAtMaxLength_ok() public {
        _setupSubmissions();
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);

        string memory maxLen = new string(280); // exactly MAX_REASON_LENGTH
        vm.prank(carol);
        arena.vote(0, maxLen);

        assertTrue(arena.hasVotedInArena(carol));
    }

    // ── finalize ──────────────────────────────────────────────────

    function _setupAndVote() internal {
        _setupSubmissions();

        // carol + owner vote for alice (id=0), bob votes for bob (id=1)
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(carol);
        arena.vote(0, "");

        vm.prank(owner);
        usdc.mint(owner, 10_000_000);
        vm.prank(owner);
        usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(owner);
        arena.vote(0, "");

        vm.warp(voteDeadline + 1);
    }

    function test_finalize_setsWinners() public {
        _setupAndVote();
        arena.finalize();

        uint256[3] memory w = arena.getWinners();
        assertEq(w[0], 1); // alice (id=0, 1-indexed=1) has 2 votes
        assertEq(w[1], 2); // bob (id=1, 1-indexed=2) has 0 votes
        assertEq(w[2], 0); // no 3rd
    }

    function test_finalize_beforeDeadline_reverts() public {
        _setupSubmissions();
        vm.expectRevert("Arena: voting not ended");
        arena.finalize();
    }

    function test_finalize_twice_reverts() public {
        _setupAndVote();
        arena.finalize();
        vm.expectRevert("Arena: already finalized");
        arena.finalize();
    }

    function test_finalize_mintsNFTs() public {
        _setupAndVote();
        arena.finalize();

        assertEq(repNFT.balanceOf(alice), 1); // 1st
        assertEq(repNFT.balanceOf(bob), 1);   // 2nd
    }

    function test_finalize_setPendingWithdraw() public {
        _setupAndVote();
        uint256 potBefore = arena.getPot();
        arena.finalize();

        uint256 expected1st = (potBefore * 6_000) / 10_000
            + (potBefore * 1_000) / 10_000; // 3rd slot empty → added to 1st
        assertEq(arena.pendingWithdraw(alice), expected1st);
    }

    function test_finalize_noSubmissions() public {
        vm.warp(voteDeadline + 1);
        uint256 pot = arena.getPot();
        arena.finalize();
        assertEq(arena.pendingWithdraw(creator), pot);
    }

    // ── withdraw ──────────────────────────────────────────────────

    function test_withdraw_winner() public {
        _setupAndVote();
        arena.finalize();

        uint256 pending = arena.pendingWithdraw(alice);
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        arena.withdraw();

        assertEq(usdc.balanceOf(alice), balBefore + pending);
        assertEq(arena.pendingWithdraw(alice), 0);
    }

    function test_withdraw_nothingPending_reverts() public {
        _setupAndVote();
        arena.finalize();

        vm.prank(carol); // carol didn't win
        vm.expectRevert("Arena: nothing to withdraw");
        arena.withdraw();
    }

    // ── claimVoterRebate ──────────────────────────────────────────

    function test_claimVoterRebate_success() public {
        _setupAndVote();
        arena.finalize();

        // carol voted for alice (winner)
        vm.prank(carol);
        arena.claimVoterRebate();

        assertEq(arena.pendingWithdraw(carol), VOTE_STAKE);
    }

    function test_claimVoterRebate_double_claim_reverts() public {
        _setupAndVote();
        arena.finalize();

        vm.prank(carol);
        arena.claimVoterRebate();

        vm.prank(carol);
        vm.expectRevert("Arena: rebate already claimed");
        arena.claimVoterRebate();
    }

    // ── getPhase ──────────────────────────────────────────────────

    function test_phase_submission() public view {
        assertEq(uint8(arena.getPhase()), uint8(Arena.Phase.Submission));
    }

    function test_phase_voting() public {
        vm.warp(subDeadline + 1);
        assertEq(uint8(arena.getPhase()), uint8(Arena.Phase.Voting));
    }

    function test_phase_ended() public {
        vm.warp(voteDeadline + 1);
        assertEq(uint8(arena.getPhase()), uint8(Arena.Phase.Ended));
    }

    // ── EDGE CASES ────────────────────────────────────────────────

    // Tiebreaker: equal votes → lower submission ID (first submitted) wins
    function test_tiebreaker_lowerIdWins() public {
        // alice submits first (id=0), bob second (id=1)
        _setupSubmissions();

        // Each gets exactly 1 vote — tie
        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(carol);
        arena.vote(0, ""); // carol votes for alice

        address dave = address(0xD);
        usdc.mint(dave, 10_000_000);
        vm.prank(dave);
        usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(dave);
        arena.vote(1, ""); // dave votes for bob

        vm.warp(voteDeadline + 1);
        arena.finalize();

        uint256[3] memory w = arena.getWinners();
        // alice (id=0) submitted first → 1st place in a tie
        assertEq(w[0], 1, "alice should win tiebreaker (lower id)");
        assertEq(w[1], 2, "bob should be 2nd");
    }

    // Single entry: 1st place gets the entire pot
    function test_finalize_singleEntry() public {
        vm.prank(alice);
        usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice);
        arena.submit("ipfs://A");

        vm.warp(voteDeadline + 1);
        uint256 pot = arena.getPot();
        arena.finalize();

        // With 1 entry: prize1 = 60% + 30% (no 2nd) + 10% (no 3rd) = 100%
        assertEq(arena.pendingWithdraw(alice), pot);
        assertEq(arena.pendingWithdraw(bob), 0);
        assertEq(arena.pendingWithdraw(creator), 0);
        assertEq(repNFT.balanceOf(alice), 1);
    }

    // Two entries: 1st gets 60%+10%=70%, 2nd gets 30%
    function test_finalize_twoEntries() public {
        _setupSubmissions(); // alice id=0, bob id=1

        vm.prank(carol);
        usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(carol);
        arena.vote(0, ""); // alice gets 1 vote

        vm.warp(voteDeadline + 1);
        uint256 pot = arena.getPot();
        arena.finalize();

        uint256 expected1st = (pot * 6_000) / 10_000 + (pot * 1_000) / 10_000; // 70%
        uint256 expected2nd = (pot * 3_000) / 10_000; // 30%
        assertEq(arena.pendingWithdraw(alice), expected1st);
        assertEq(arena.pendingWithdraw(bob), expected2nd);
        assertEq(repNFT.balanceOf(alice), 1);
        assertEq(repNFT.balanceOf(bob), 1);
        assertEq(repNFT.balanceOf(carol), 0); // voter doesn't get NFT
    }

    // Full 60/30/10 split with 3 entries
    function test_finalize_threeEntries_fullSplit() public {
        address eve = address(0xE);
        usdc.mint(eve, 10_000_000);

        vm.prank(alice); usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice); arena.submit("ipfs://A");
        vm.prank(bob);   usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(bob);   arena.submit("ipfs://B");
        vm.prank(carol); usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(carol); arena.submit("ipfs://C");

        vm.warp(subDeadline + 1);

        // alice:3 votes, bob:2 votes, carol:1 vote
        address[3] memory voters = [address(0x20), address(0x21), address(0x22)];
        for (uint i = 0; i < 3; i++) {
            usdc.mint(voters[i], 10_000_000);
            vm.prank(voters[i]); usdc.approve(address(arena), VOTE_STAKE);
            vm.prank(voters[i]); arena.vote(0, ""); // vote for alice
        }
        address[2] memory voters2 = [address(0x23), address(0x24)];
        for (uint i = 0; i < 2; i++) {
            usdc.mint(voters2[i], 10_000_000);
            vm.prank(voters2[i]); usdc.approve(address(arena), VOTE_STAKE);
            vm.prank(voters2[i]); arena.vote(1, ""); // vote for bob
        }
        vm.prank(eve); usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(eve); arena.vote(2, ""); // vote for carol

        vm.warp(voteDeadline + 1);
        uint256 pot = arena.getPot();
        arena.finalize();

        assertEq(arena.pendingWithdraw(alice), (pot * 6_000) / 10_000);
        assertEq(arena.pendingWithdraw(bob),   (pot * 3_000) / 10_000);
        assertEq(arena.pendingWithdraw(carol),  (pot * 1_000) / 10_000);

        assertEq(repNFT.balanceOf(alice), 1);
        assertEq(repNFT.balanceOf(bob),   1);
        assertEq(repNFT.balanceOf(carol),  1);
    }

    // Pot conservation: total distributed == pot (no USDC lost or created)
    function test_finalize_potConservation() public {
        address eve = address(0xE);
        usdc.mint(eve, 10_000_000);

        vm.prank(alice); usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice); arena.submit("ipfs://A");
        vm.prank(bob);   usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(bob);   arena.submit("ipfs://B");
        vm.prank(carol); usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(carol); arena.submit("ipfs://C");

        vm.warp(subDeadline + 1);
        vm.prank(eve); usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(eve); arena.vote(0, "");

        vm.warp(voteDeadline + 1);
        uint256 pot = arena.getPot();
        arena.finalize();

        // Sum of all pending withdrawals must equal the pot at time of finalize
        uint256 total = arena.pendingWithdraw(alice)
            + arena.pendingWithdraw(bob)
            + arena.pendingWithdraw(carol)
            + arena.pendingWithdraw(creator); // dust if any
        assertEq(total, pot, "pot conservation violated");
    }

    // Pot correctly accumulates submission fees + vote stakes + initial prize
    function test_pot_accumulates_fees() public {
        uint256 initialPot = arena.getPot(); // seeded PRIZE_POOL

        vm.prank(alice); usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice); arena.submit("ipfs://A");
        assertEq(arena.getPot(), initialPot + SUBMISSION_FEE);

        vm.prank(bob); usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(bob); arena.submit("ipfs://B");
        assertEq(arena.getPot(), initialPot + SUBMISSION_FEE * 2);

        vm.warp(subDeadline + 1);
        vm.prank(carol); usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(carol); arena.vote(0, "");
        assertEq(arena.getPot(), initialPot + SUBMISSION_FEE * 2 + VOTE_STAKE);
    }

    // Max submissions cap
    function test_submit_maxCap() public {
        // Submit MAX_SUBMISSIONS (100) entries
        for (uint256 i = 0; i < 100; i++) {
            address submitter = address(uint160(0x1000 + i));
            usdc.mint(submitter, SUBMISSION_FEE);
            vm.prank(submitter); usdc.approve(address(arena), SUBMISSION_FEE);
            vm.prank(submitter); arena.submit(string.concat("ipfs://", vm.toString(i)));
        }
        assertEq(arena.getSubmissionCount(), 100);

        // 101st should revert
        address over = address(0x9999);
        usdc.mint(over, SUBMISSION_FEE);
        vm.prank(over); usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(over);
        vm.expectRevert("Arena: submission cap reached");
        arena.submit("ipfs://over");
    }

    // Voter who voted for loser cannot claim rebate
    function test_claimVoterRebate_loser_reverts() public {
        // alice and bob submit
        vm.prank(alice); usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice); arena.submit("ipfs://A");
        vm.prank(bob);   usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(bob);   arena.submit("ipfs://B");

        vm.warp(subDeadline + 1);

        // carol votes for alice, dave votes for bob
        address dave = address(0xD);
        usdc.mint(dave, 10_000_000);

        vm.prank(carol); usdc.approve(address(arena), VOTE_STAKE * 2);
        vm.prank(carol); arena.vote(0, ""); // carol → alice (will win with 1 vote vs 0)
        vm.prank(dave);  usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(dave);  arena.vote(1, ""); // dave → bob (loser)

        vm.warp(voteDeadline + 1);
        arena.finalize();

        // dave voted for bob (loser) — no rebate
        vm.prank(dave);
        vm.expectRevert("Arena: voted for loser");
        arena.claimVoterRebate();
    }

    // claimVoterRebate before finalize reverts
    function test_claimVoterRebate_beforeFinalize_reverts() public {
        _setupSubmissions();
        vm.prank(carol); usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(carol); arena.vote(0, "");
        vm.warp(voteDeadline + 1);
        // NOT finalized yet
        vm.prank(carol);
        vm.expectRevert("Arena: not finalized");
        arena.claimVoterRebate();
    }

    // Non-voter cannot claim rebate
    function test_claimVoterRebate_nonVoter_reverts() public {
        _setupAndVote();
        arena.finalize();
        address dave = address(0xD);
        vm.prank(dave);
        vm.expectRevert("Arena: did not vote");
        arena.claimVoterRebate();
    }

    // Double withdraw reverts
    function test_withdraw_double_reverts() public {
        _setupAndVote();
        arena.finalize();
        vm.prank(alice);
        arena.withdraw();
        vm.prank(alice);
        vm.expectRevert("Arena: nothing to withdraw");
        arena.withdraw();
    }

    // Winner can withdraw + claim rebate (if they also voted for themselves, but that's blocked by hasSubmitted logic — they CAN vote if they vote for someone else)
    // Actually: submitter != voter restriction doesn't exist, a submitter CAN vote for another entry
    function test_submitter_can_vote_for_others() public {
        _setupSubmissions(); // alice id=0, bob id=1
        // alice votes for bob (she can)
        vm.prank(alice); usdc.approve(address(arena), VOTE_STAKE);
        vm.prank(alice); arena.vote(1, "");
        assertTrue(arena.hasVotedInArena(alice));
    }

    // getSubmissions returns full array
    function test_getSubmissions_array() public {
        vm.prank(alice); usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(alice); arena.submit("ipfs://A");
        vm.prank(bob);   usdc.approve(address(arena), SUBMISSION_FEE);
        vm.prank(bob);   arena.submit("ipfs://B");

        Arena.Submission[] memory subs = arena.getSubmissions();
        assertEq(subs.length, 2);
        assertEq(subs[0].submitter, alice);
        assertEq(subs[1].submitter, bob);
    }
}
