"use client";

import { useReadContracts, useAccount } from "wagmi";
import { ARENA_ABI, ERC20_APPROVE_ABI, ArenaPhase, type ArenaSubmission } from "@/lib/contracts";
import { USDC_ADDRESS, SUBMISSION_FEE, VOTE_STAKE } from "@/lib/usdc";
import { arcTestnet } from "@/lib/chain";

export type ArenaDetail = {
  address: `0x${string}`;
  topic: string;
  creator: `0x${string}`;
  pot: bigint;
  phase: ArenaPhase;
  submissions: ArenaSubmission[];
  submissionCount: bigint;
  submissionDeadline: bigint;
  votingDeadline: bigint;
  finalized: boolean;
  winners: readonly [bigint, bigint, bigint];
  // viewer-specific
  hasSubmitted: boolean;
  hasVoted: boolean;
  pendingWithdraw: bigint;
  usdcBalance: bigint;
  usdcAllowance: bigint;
};

export function useArena(arenaAddress: `0x${string}` | undefined) {
  const { address: viewer } = useAccount();

  const arena = arenaAddress as `0x${string}`;
  const enabled = !!arenaAddress;

  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      { address: arena, abi: ARENA_ABI, functionName: "topic" },
      { address: arena, abi: ARENA_ABI, functionName: "creator" },
      { address: arena, abi: ARENA_ABI, functionName: "getPot" },
      { address: arena, abi: ARENA_ABI, functionName: "getPhase" },
      { address: arena, abi: ARENA_ABI, functionName: "getSubmissions" },
      { address: arena, abi: ARENA_ABI, functionName: "getSubmissionCount" },
      { address: arena, abi: ARENA_ABI, functionName: "submissionDeadline" },
      { address: arena, abi: ARENA_ABI, functionName: "votingDeadline" },
      { address: arena, abi: ARENA_ABI, functionName: "finalized" },
      { address: arena, abi: ARENA_ABI, functionName: "getWinners" },
      // viewer-specific (only useful when connected)
      {
        address: arena,
        abi: ARENA_ABI,
        functionName: "hasSubmitted",
        args: viewer ? [viewer] : undefined,
      },
      {
        address: arena,
        abi: ARENA_ABI,
        functionName: "hasVotedInArena",
        args: viewer ? [viewer] : undefined,
      },
      {
        address: arena,
        abi: ARENA_ABI,
        functionName: "pendingWithdraw",
        args: viewer ? [viewer] : undefined,
      },
      // USDC balance + allowance for the connected viewer
      {
        address: USDC_ADDRESS,
        abi: ERC20_APPROVE_ABI,
        functionName: "balanceOf",
        args: viewer ? [viewer] : undefined,
      },
      {
        address: USDC_ADDRESS,
        abi: ERC20_APPROVE_ABI,
        functionName: "allowance",
        args: viewer ? [viewer, arena] : undefined,
      },
    ],
    chainId: arcTestnet.id,
    query: { enabled, refetchInterval: 30_000 },
  });

  if (!data || !arenaAddress) {
    return { detail: null, isLoading, refetch };
  }

  const get = (i: number) => data[i]?.result;

  const detail: ArenaDetail = {
    address: arenaAddress,
    topic: (get(0) as string) ?? "",
    creator: (get(1) as `0x${string}`) ?? "0x",
    pot: (get(2) as bigint) ?? 0n,
    phase: (get(3) as ArenaPhase) ?? ArenaPhase.Submission,
    submissions: (get(4) as ArenaSubmission[]) ?? [],
    submissionCount: (get(5) as bigint) ?? 0n,
    submissionDeadline: (get(6) as bigint) ?? 0n,
    votingDeadline: (get(7) as bigint) ?? 0n,
    finalized: (get(8) as boolean) ?? false,
    winners: (get(9) as readonly [bigint, bigint, bigint]) ?? [0n, 0n, 0n],
    hasSubmitted: (get(10) as boolean) ?? false,
    hasVoted: (get(11) as boolean) ?? false,
    pendingWithdraw: (get(12) as bigint) ?? 0n,
    usdcBalance: (get(13) as bigint) ?? 0n,
    usdcAllowance: (get(14) as bigint) ?? 0n,
  };

  return { detail, isLoading, refetch };
}

// Helper: can the viewer submit?
export function canSubmit(detail: ArenaDetail, isConnected: boolean): { ok: boolean; reason?: string } {
  if (!isConnected) return { ok: false, reason: "Connect wallet" };
  if (detail.phase !== ArenaPhase.Submission) return { ok: false, reason: "Submission phase ended" };
  if (detail.hasSubmitted) return { ok: false, reason: "Already submitted" };
  if (detail.usdcBalance < SUBMISSION_FEE) return { ok: false, reason: "Insufficient USDC (need 0.10)" };
  return { ok: true };
}

// Helper: can the viewer vote?
export function canVote(detail: ArenaDetail, isConnected: boolean): { ok: boolean; reason?: string } {
  if (!isConnected) return { ok: false, reason: "Connect wallet" };
  if (detail.phase !== ArenaPhase.Voting) return { ok: false, reason: "Not in voting phase" };
  if (detail.hasVoted) return { ok: false, reason: "Already voted" };
  if (detail.submissionCount === 0n) return { ok: false, reason: "No submissions" };
  if (detail.usdcBalance < VOTE_STAKE) return { ok: false, reason: "Insufficient USDC (need 0.05)" };
  return { ok: true };
}
