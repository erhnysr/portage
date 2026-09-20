"use client";

import { useReadContract, useReadContracts } from "wagmi";
import {
  ARENA_FACTORY_ADDRESS,
  ARENA_FACTORY_ABI,
  ARENA_ABI,
  REPUTATION_NFT_ADDRESS,
  ArenaPhase,
} from "@/lib/contracts";
import { arcTestnet } from "@/lib/chain";

const REP_NFT_ABI = [
  {
    "type": "function", "name": "getWinRecords",
    "inputs": [{ "name": "owner", "type": "address" }],
    "outputs": [{
      "name": "", "type": "tuple[]",
      "components": [
        { "name": "arena", "type": "address" },
        { "name": "category", "type": "string" },
        { "name": "rank", "type": "uint8" },
        { "name": "timestamp", "type": "uint256" },
      ]
    }],
    "stateMutability": "view"
  },
] as const;

export type WinRecord = {
  arena: `0x${string}`;
  category: string;
  rank: number;
  timestamp: bigint;
};

export type ProfileArena = {
  address: `0x${string}`;
  topic: string;
  phase: ArenaPhase;
  pot: bigint;
  submissionCount: bigint;
};

export function useProfile(userAddress: `0x${string}` | undefined) {
  const factoryReady = ARENA_FACTORY_ADDRESS.length > 2;
  const nftReady = REPUTATION_NFT_ADDRESS.length > 2;
  const enabled = !!userAddress;

  // ── Created arenas ──────────────────────────────────────────────
  const { data: createdAddresses, isLoading: loadingCreated } = useReadContract({
    address: factoryReady ? ARENA_FACTORY_ADDRESS : undefined,
    abi: ARENA_FACTORY_ABI,
    functionName: "getArenasByCreator",
    args: userAddress ? [userAddress] : undefined,
    chainId: arcTestnet.id,
    query: { enabled: enabled && factoryReady, refetchInterval: 30_000 },
  });

  const createdAddrs = (createdAddresses ?? []) as `0x${string}`[];

  const { data: createdDetails, isLoading: loadingCreatedDetails } = useReadContracts({
    contracts: createdAddrs.flatMap((addr) => [
      { address: addr, abi: ARENA_ABI, functionName: "topic" },
      { address: addr, abi: ARENA_ABI, functionName: "getPhase" },
      { address: addr, abi: ARENA_ABI, functionName: "getPot" },
      { address: addr, abi: ARENA_ABI, functionName: "getSubmissionCount" },
    ]),
    chainId: arcTestnet.id,
    query: { enabled: createdAddrs.length > 0, refetchInterval: 30_000 },
  });

  const createdArenas: ProfileArena[] = [];
  if (createdDetails) {
    for (let i = 0; i < createdAddrs.length; i++) {
      const b = i * 4;
      createdArenas.push({
        address: createdAddrs[i],
        topic: (createdDetails[b]?.result as string) ?? "",
        phase: (createdDetails[b + 1]?.result as ArenaPhase) ?? ArenaPhase.Submission,
        pot: (createdDetails[b + 2]?.result as bigint) ?? 0n,
        submissionCount: (createdDetails[b + 3]?.result as bigint) ?? 0n,
      });
    }
  }

  // ── All arenas → find submitted ones ───────────────────────────
  const { data: allAddresses, isLoading: loadingAll } = useReadContract({
    address: factoryReady ? ARENA_FACTORY_ADDRESS : undefined,
    abi: ARENA_FACTORY_ABI,
    functionName: "getArenas",
    chainId: arcTestnet.id,
    query: { enabled: enabled && factoryReady, refetchInterval: 30_000 },
  });

  const allAddrs = (allAddresses ?? []) as `0x${string}`[];

  // Multicall: hasSubmitted(user) + topic + phase + pot per arena
  const { data: submittedData, isLoading: loadingSubmitted } = useReadContracts({
    contracts: allAddrs.flatMap((addr) => [
      { address: addr, abi: ARENA_ABI, functionName: "hasSubmitted", args: userAddress ? [userAddress] : undefined },
      { address: addr, abi: ARENA_ABI, functionName: "topic" },
      { address: addr, abi: ARENA_ABI, functionName: "getPhase" },
      { address: addr, abi: ARENA_ABI, functionName: "getPot" },
      { address: addr, abi: ARENA_ABI, functionName: "getSubmissionCount" },
    ]),
    chainId: arcTestnet.id,
    query: { enabled: allAddrs.length > 0 && enabled, refetchInterval: 30_000 },
  });

  const submittedArenas: ProfileArena[] = [];
  if (submittedData && userAddress) {
    for (let i = 0; i < allAddrs.length; i++) {
      const b = i * 5;
      const hasSubmitted = submittedData[b]?.result as boolean | undefined;
      if (!hasSubmitted) continue;
      // Exclude arenas the user created (already shown in Created section)
      if (createdAddrs.includes(allAddrs[i])) continue;
      submittedArenas.push({
        address: allAddrs[i],
        topic: (submittedData[b + 1]?.result as string) ?? "",
        phase: (submittedData[b + 2]?.result as ArenaPhase) ?? ArenaPhase.Submission,
        pot: (submittedData[b + 3]?.result as bigint) ?? 0n,
        submissionCount: (submittedData[b + 4]?.result as bigint) ?? 0n,
      });
    }
  }

  // ── Reputation NFT win records ──────────────────────────────────
  const { data: winRecordsRaw, isLoading: loadingNFT } = useReadContract({
    address: nftReady ? (REPUTATION_NFT_ADDRESS as `0x${string}`) : undefined,
    abi: REP_NFT_ABI,
    functionName: "getWinRecords",
    args: userAddress ? [userAddress] : undefined,
    chainId: arcTestnet.id,
    query: { enabled: enabled && nftReady, refetchInterval: 30_000 },
  });

  const winRecords: WinRecord[] = ((winRecordsRaw ?? []) as WinRecord[]).map((r) => ({
    arena: r.arena,
    category: r.category,
    rank: Number(r.rank),
    timestamp: r.timestamp,
  }));

  return {
    createdArenas,
    submittedArenas,
    winRecords,
    isLoading: loadingCreated || loadingCreatedDetails || loadingAll || loadingSubmitted || loadingNFT,
    factoryReady,
    nftReady,
  };
}
