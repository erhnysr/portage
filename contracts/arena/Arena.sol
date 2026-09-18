// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ReputationNFT.sol";

/// @notice A single judging arena. Deployed by ArenaFactory.
contract Arena {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────────────
    // Types
    // ────────────────────────────────────────────────────────────────

    struct Submission {
        address submitter;
        string contentRef; // IPFS hash or URL
        uint256 votes;
        uint256 submittedAt;
    }

    enum Phase {
        Submission, // before submissionDeadline
        Voting,     // between submissionDeadline and votingDeadline
        Ended       // after votingDeadline (finalized or not yet)
    }

    // ────────────────────────────────────────────────────────────────
    // Constants  (6 decimals — ERC-20 USDC)
    // ────────────────────────────────────────────────────────────────

    uint256 public constant SUBMISSION_FEE = 100_000; // 0.10 USDC
    uint256 public constant VOTE_STAKE = 50_000;      // 0.05 USDC
    uint256 public constant MAX_SUBMISSIONS = 100;
    uint256 public constant MAX_REASON_LENGTH = 280;  // vote reason cap (tweet-length)

    // Prize split basis points (must sum to 10_000)
    uint256 private constant SPLIT_1ST = 6_000; // 60%
    uint256 private constant SPLIT_2ND = 3_000; // 30%
    uint256 private constant SPLIT_3RD = 1_000; // 10%

    // ────────────────────────────────────────────────────────────────
    // Immutables
    // ────────────────────────────────────────────────────────────────

    address public immutable factory;
    address public immutable creator;
    IERC20 public immutable usdc;         // Arc Testnet: 0x3600...0000, 6 decimals
    ReputationNFT public immutable repNFT;

    string public topic;
    uint256 public submissionDeadline;
    uint256 public votingDeadline;

    // ────────────────────────────────────────────────────────────────
    // State
    // ────────────────────────────────────────────────────────────────

    bool public finalized;
    uint256[3] public winners; // [1st, 2nd, 3rd] submission IDs (1-indexed; 0 = no winner)

    Submission[] private _submissions;

    // One vote per address per arena (updated per plan)
    mapping(address => bool) public hasVotedInArena;
    mapping(address => uint256) public voterChoice; // which submission ID (1-indexed)

    mapping(address => bool) public hasSubmitted;

    // Withdrawable balances: winners + voters who voted for the winner
    mapping(address => uint256) public pendingWithdraw;

    // ────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────

    event SubmissionCreated(uint256 indexed id, address indexed submitter, string contentRef);
    /// @dev `reason` is event-only (never stored) — read off-chain via indexer. Empty allowed.
    event Voted(uint256 indexed submissionId, address indexed voter, string reason);
    event Finalized(uint256 first, uint256 second, uint256 third);
    event Withdrawn(address indexed recipient, uint256 amount);

    // ────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────

    constructor(
        address _creator,
        address _usdc,
        address _repNFT,
        string memory _topic,
        uint256 _submissionDeadline,
        uint256 _votingDeadline
    ) {
        require(_creator != address(0), "Arena: zero creator");
        require(_submissionDeadline > block.timestamp, "Arena: submission deadline in past");
        require(_votingDeadline > _submissionDeadline, "Arena: voting deadline before submission");

        factory = msg.sender;
        creator = _creator;
        usdc = IERC20(_usdc);
        repNFT = ReputationNFT(_repNFT);
        topic = _topic;
        submissionDeadline = _submissionDeadline;
        votingDeadline = _votingDeadline;

        // Prize pool is sent by ArenaFactory via safeTransfer after deployment
    }

    // ────────────────────────────────────────────────────────────────
    // Write functions
    // ────────────────────────────────────────────────────────────────

    /// @notice Submit an entry. Requires prior USDC approval of SUBMISSION_FEE.
    function submit(string calldata contentRef) external {
        require(block.timestamp < submissionDeadline, "Arena: submission phase ended");
        require(!hasSubmitted[msg.sender], "Arena: already submitted");
        require(_submissions.length < MAX_SUBMISSIONS, "Arena: submission cap reached");
        require(bytes(contentRef).length > 0, "Arena: empty content ref");

        usdc.safeTransferFrom(msg.sender, address(this), SUBMISSION_FEE);

        uint256 id = _submissions.length; // 0-indexed internally, +1 for external display
        _submissions.push(Submission({
            submitter: msg.sender,
            contentRef: contentRef,
            votes: 0,
            submittedAt: block.timestamp
        }));
        hasSubmitted[msg.sender] = true;

        emit SubmissionCreated(id, msg.sender, contentRef);
    }

    /// @notice Cast your ONE vote for this arena. Requires prior USDC approval of VOTE_STAKE.
    /// @param submissionId 0-indexed submission ID
    /// @param reason Optional (may be empty) public justification for the vote. Not stored —
    ///        emitted in the Voted event only, so gas is paid by the voter and read off-chain.
    function vote(uint256 submissionId, string calldata reason) external {
        require(block.timestamp >= submissionDeadline, "Arena: voting not started");
        require(block.timestamp < votingDeadline, "Arena: voting phase ended");
        require(!hasVotedInArena[msg.sender], "Arena: already voted");
        require(submissionId < _submissions.length, "Arena: invalid submission");
        require(bytes(reason).length <= MAX_REASON_LENGTH, "Arena: reason too long");

        usdc.safeTransferFrom(msg.sender, address(this), VOTE_STAKE);

        _submissions[submissionId].votes++;
        hasVotedInArena[msg.sender] = true;
        voterChoice[msg.sender] = submissionId;

        emit Voted(submissionId, msg.sender, reason);
    }

    /// @notice Finalize the arena after votingDeadline. Anyone may call.
    function finalize() external {
        require(block.timestamp >= votingDeadline, "Arena: voting not ended");
        require(!finalized, "Arena: already finalized");

        finalized = true;

        uint256 count = _submissions.length;

        if (count == 0) {
            // No submissions: creator gets everything back
            pendingWithdraw[creator] += _usdcBalance();
            emit Finalized(0, 0, 0);
            return;
        }

        // Determine top-3 by votes desc, tiebreak: lower ID wins (first submitted)
        uint256[3] memory topIds;  // 1-indexed: 0 = no entry
        uint256[3] memory topVotes;

        for (uint256 i = 0; i < count; i++) {
            uint256 v = _submissions[i].votes;
            if (topIds[0] == 0 || v > topVotes[0] || (v == topVotes[0] && i < topIds[0] - 1)) {
                topIds[2] = topIds[1]; topVotes[2] = topVotes[1];
                topIds[1] = topIds[0]; topVotes[1] = topVotes[0];
                topIds[0] = i + 1;    topVotes[0] = v;
            } else if (topIds[1] == 0 || v > topVotes[1] || (v == topVotes[1] && i < topIds[1] - 1)) {
                topIds[2] = topIds[1]; topVotes[2] = topVotes[1];
                topIds[1] = i + 1;    topVotes[1] = v;
            } else if (topIds[2] == 0 || v > topVotes[2] || (v == topVotes[2] && i < topIds[2] - 1)) {
                topIds[2] = i + 1;    topVotes[2] = v;
            }
        }

        winners = topIds;

        uint256 pot = _usdcBalance();

        // Compute prizes only for filled slots; unfilled share collapses to 1st
        uint256 prize1 = 0;
        uint256 prize2 = 0;
        uint256 prize3 = 0;

        if (topIds[0] != 0) {
            prize1 = (pot * SPLIT_1ST) / 10_000;
        }
        if (topIds[1] != 0) {
            prize2 = (pot * SPLIT_2ND) / 10_000;
        } else {
            prize1 += (pot * SPLIT_2ND) / 10_000; // no 2nd → add to 1st
        }
        if (topIds[2] != 0) {
            prize3 = (pot * SPLIT_3RD) / 10_000;
        } else {
            prize1 += (pot * SPLIT_3RD) / 10_000; // no 3rd → add to 1st
        }

        if (topIds[0] != 0) {
            address w1 = _submissions[topIds[0] - 1].submitter;
            pendingWithdraw[w1] += prize1;
            repNFT.mint(w1, address(this), topic, 1);
        }
        if (topIds[1] != 0) {
            address w2 = _submissions[topIds[1] - 1].submitter;
            pendingWithdraw[w2] += prize2;
            repNFT.mint(w2, address(this), topic, 2);
        }
        if (topIds[2] != 0) {
            address w3 = _submissions[topIds[2] - 1].submitter;
            pendingWithdraw[w3] += prize3;
            repNFT.mint(w3, address(this), topic, 3);
        }

        // Rounding dust → creator
        uint256 distributed = prize1 + prize2 + prize3;
        if (pot > distributed) {
            pendingWithdraw[creator] += pot - distributed;
        }

        emit Finalized(topIds[0], topIds[1], topIds[2]);
    }

    /// @notice Claim pending winnings or voter rebate. CEI pattern.
    function withdraw() external {
        uint256 amount = pendingWithdraw[msg.sender];
        require(amount > 0, "Arena: nothing to withdraw");
        pendingWithdraw[msg.sender] = 0;
        usdc.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Voters who voted for the 1st-place submission can claim their stake back.
    ///         Uses type(uint256).max as a "claimed" sentinel in voterChoice.
    function claimVoterRebate() external {
        require(finalized, "Arena: not finalized");
        require(hasVotedInArena[msg.sender], "Arena: did not vote");
        require(voterChoice[msg.sender] != type(uint256).max, "Arena: rebate already claimed");
        require(winners[0] != 0, "Arena: no winner");
        require(voterChoice[msg.sender] == winners[0] - 1, "Arena: voted for loser");

        voterChoice[msg.sender] = type(uint256).max; // mark claimed
        pendingWithdraw[msg.sender] += VOTE_STAKE;
    }

    // ────────────────────────────────────────────────────────────────
    // View functions
    // ────────────────────────────────────────────────────────────────

    function getSubmission(uint256 id) external view returns (Submission memory) {
        require(id < _submissions.length, "Arena: invalid id");
        return _submissions[id];
    }

    function getSubmissions() external view returns (Submission[] memory) {
        return _submissions;
    }

    function getSubmissionCount() external view returns (uint256) {
        return _submissions.length;
    }

    function getPhase() external view returns (Phase) {
        if (block.timestamp < submissionDeadline) return Phase.Submission;
        if (block.timestamp < votingDeadline) return Phase.Voting;
        return Phase.Ended;
    }

    function getPot() external view returns (uint256) {
        return _usdcBalance();
    }

    function getWinners() external view returns (uint256[3] memory) {
        return winners;
    }

    // ────────────────────────────────────────────────────────────────
    // Internal
    // ────────────────────────────────────────────────────────────────

    function _usdcBalance() internal view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
