import { getNetwork } from "@erhnysr/portage-sdk";

// Arena contract addresses come from the Portage SDK network config (single source of truth) —
// SPEC §7 — not hardcoded here. This resolves to the canonical Arc Testnet deployment
// (ArenaFactory 0x13a38e7C…, ReputationNFT 0x953f508C…), matching contracts/arena/.
const arcTestnet = getNetwork("arcTestnet");
export const ARENA_FACTORY_ADDRESS = arcTestnet.arena.arenaFactory as `0x${string}`;
export const REPUTATION_NFT_ADDRESS = arcTestnet.arena.reputationNft as `0x${string}`;

export const ARENA_FACTORY_ABI = [
  {
    "type": "function", "name": "USDC",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "createArena",
    "inputs": [
      { "name": "topic", "type": "string" },
      { "name": "prizePool", "type": "uint256" },
      { "name": "submissionDeadline", "type": "uint256" },
      { "name": "votingDeadline", "type": "uint256" }
    ],
    "outputs": [{ "name": "arena", "type": "address" }],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "getArenas",
    "inputs": [], "outputs": [{ "name": "", "type": "address[]" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "getArenasByCreator",
    "inputs": [{ "name": "creator", "type": "address" }],
    "outputs": [{ "name": "", "type": "address[]" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "getArenaCount",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "reputationNFT",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "event", "name": "ArenaCreated",
    "inputs": [
      { "name": "arena", "type": "address", "indexed": true },
      { "name": "creator", "type": "address", "indexed": true },
      { "name": "topic", "type": "string", "indexed": false },
      { "name": "prizePool", "type": "uint256", "indexed": false },
      { "name": "submissionDeadline", "type": "uint256", "indexed": false },
      { "name": "votingDeadline", "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  }
] as const;

export const ARENA_ABI = [
  {
    "type": "function", "name": "topic",
    "inputs": [], "outputs": [{ "name": "", "type": "string" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "creator",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "submissionDeadline",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "votingDeadline",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "finalized",
    "inputs": [], "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "getPhase",
    "inputs": [], "outputs": [{ "name": "", "type": "uint8" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "getPot",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "getSubmissionCount",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "getSubmissions",
    "inputs": [],
    "outputs": [{
      "name": "", "type": "tuple[]",
      "components": [
        { "name": "submitter", "type": "address" },
        { "name": "contentRef", "type": "string" },
        { "name": "votes", "type": "uint256" },
        { "name": "submittedAt", "type": "uint256" }
      ]
    }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "getWinners",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256[3]" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "hasSubmitted",
    "inputs": [{ "name": "", "type": "address" }],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "hasVotedInArena",
    "inputs": [{ "name": "", "type": "address" }],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "pendingWithdraw",
    "inputs": [{ "name": "", "type": "address" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "SUBMISSION_FEE",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "VOTE_STAKE",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "submit",
    "inputs": [{ "name": "contentRef", "type": "string" }],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "vote",
    "inputs": [
      { "name": "submissionId", "type": "uint256" },
      { "name": "reason", "type": "string" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "finalize",
    "inputs": [], "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "withdraw",
    "inputs": [], "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "claimVoterRebate",
    "inputs": [], "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event", "name": "SubmissionCreated",
    "inputs": [
      { "name": "id", "type": "uint256", "indexed": true },
      { "name": "submitter", "type": "address", "indexed": true },
      { "name": "contentRef", "type": "string", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "Voted",
    "inputs": [
      { "name": "submissionId", "type": "uint256", "indexed": true },
      { "name": "voter", "type": "address", "indexed": true },
      { "name": "reason", "type": "string", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "Finalized",
    "inputs": [
      { "name": "first", "type": "uint256", "indexed": false },
      { "name": "second", "type": "uint256", "indexed": false },
      { "name": "third", "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "Withdrawn",
    "inputs": [
      { "name": "recipient", "type": "address", "indexed": true },
      { "name": "amount", "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  }
] as const;

export const ERC20_APPROVE_ABI = [
  {
    "type": "function", "name": "approve",
    "inputs": [
      { "name": "spender", "type": "address" },
      { "name": "amount", "type": "uint256" }
    ],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "allowance",
    "inputs": [
      { "name": "owner", "type": "address" },
      { "name": "spender", "type": "address" }
    ],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "balanceOf",
    "inputs": [{ "name": "account", "type": "address" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  }
] as const;

// Max length of a vote reason (matches Arena.MAX_REASON_LENGTH)
export const MAX_VOTE_REASON = 280;

// Phase enum (matches Arena.sol)
export enum ArenaPhase {
  Submission = 0,
  Voting = 1,
  Ended = 2,
}

export type ArenaSubmission = {
  submitter: `0x${string}`;
  contentRef: string;
  votes: bigint;
  submittedAt: bigint;
};
