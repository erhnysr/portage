// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Arena.sol";
import "./ReputationNFT.sol";

/// @notice Deploys and tracks Arena instances. Single entry point for the frontend.
contract ArenaFactory {
    using SafeERC20 for IERC20;

    // Arc Testnet USDC — ERC-20 interface, 6 decimals
    address public constant USDC = 0x3600000000000000000000000000000000000000;

    address public immutable reputationNFT;

    address[] private _arenas;
    mapping(address => address[]) private _arenasByCreator;

    event ArenaCreated(
        address indexed arena,
        address indexed creator,
        string topic,
        uint256 prizePool,
        uint256 submissionDeadline,
        uint256 votingDeadline
    );

    constructor(address _reputationNFT) {
        require(_reputationNFT != address(0), "ArenaFactory: zero repNFT");
        reputationNFT = _reputationNFT;
    }

    /// @notice Create a new Arena. Creator must approve (prizePool) USDC to this factory first.
    /// @param topic        Short description of the contest
    /// @param prizePool    Initial prize in USDC (6 decimals). May be 0.
    /// @param submissionDeadline Unix timestamp for end of submission phase
    /// @param votingDeadline     Unix timestamp for end of voting phase
    function createArena(
        string calldata topic,
        uint256 prizePool,
        uint256 submissionDeadline,
        uint256 votingDeadline
    ) external returns (address arena) {
        require(bytes(topic).length > 0, "ArenaFactory: empty topic");
        require(submissionDeadline > block.timestamp, "ArenaFactory: submission deadline in past");
        require(votingDeadline > submissionDeadline, "ArenaFactory: voting before submission");

        // 1. Pull prize pool from creator into this factory (user approves factory)
        if (prizePool > 0) {
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), prizePool);
        }

        // 2. Deploy arena
        arena = address(
            new Arena(
                msg.sender,
                USDC,
                reputationNFT,
                topic,
                submissionDeadline,
                votingDeadline
            )
        );

        // 3. Forward prize pool to the newly deployed arena
        if (prizePool > 0) {
            IERC20(USDC).safeTransfer(arena, prizePool);
        }

        // 4. Authorize arena to mint ReputationNFTs
        ReputationNFT(reputationNFT).authorizeArena(arena);

        _arenas.push(arena);
        _arenasByCreator[msg.sender].push(arena);

        emit ArenaCreated(arena, msg.sender, topic, prizePool, submissionDeadline, votingDeadline);
    }

    // ────────────────────────────────────────────────────────────────
    // View
    // ────────────────────────────────────────────────────────────────

    function getArenas() external view returns (address[] memory) {
        return _arenas;
    }

    function getArenasByCreator(address creator) external view returns (address[] memory) {
        return _arenasByCreator[creator];
    }

    function getArenaCount() external view returns (uint256) {
        return _arenas.length;
    }
}
