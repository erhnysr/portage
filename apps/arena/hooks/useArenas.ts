"use client";

import { useReadContract, useReadContracts } from "wagmi";
import { ARENA_FACTORY_ADDRESS, ARENA_FACTORY_ABI, ARENA_ABI, ArenaPhase } from "@/lib/contracts";
import { arcTestnet } from "@/lib/chain";

export type ArenaInfo = {
  address: `0x${string}`;
  topic: string;
  pot: bigint;
  phase: ArenaPhase;
  submissionCount: bigint;
  submissionDeadline: bigint;
  votingDeadline: bigint;
  finalized: boolean;
};

const FIELDS = ["topic", "getPot", "getPhase", "getSubmissionCount", "submissionDeadline", "votingDeadline", "finalized"] as const;

export function useArenas() {
  const factoryReady = ARENA_FACTORY_ADDRESS.length > 2;

  // Step 1: fetch all arena addresses from factory
  const { data: addresses, isLoading: loadingAddresses, error: addressesError } = useReadContract({
    address: factoryReady ? ARENA_FACTORY_ADDRESS : undefined,
    abi: ARENA_FACTORY_ABI,
    functionName: "getArenas",
    chainId: arcTestnet.id,
    query: { enabled: factoryReady, refetchInterval: 30_000 },
  });

  if (addressesError) console.error("[useArenas] getArenas error:", addressesError);

  const arenaAddresses = (addresses ?? []) as `0x${string}`[];

  // Step 2: multicall — read 7 fields per arena in one RPC call
  const contracts = arenaAddresses.flatMap((addr) =>
    FIELDS.map((fn) => ({
      address: addr,
      abi: ARENA_ABI,
      functionName: fn,
    }))
  );

  const { data: results, isLoading: loadingDetails, error: detailsError } = useReadContracts({
    contracts,
    chainId: arcTestnet.id,
    query: { enabled: arenaAddresses.length > 0, refetchInterval: 30_000 },
  });

  if (detailsError) console.error("[useArenas] multicall error:", detailsError);

  const arenas: ArenaInfo[] = [];

  if (results && arenaAddresses.length > 0) {
    for (let i = 0; i < arenaAddresses.length; i++) {
      const base = i * FIELDS.length;
      const get = (offset: number) => results[base + offset]?.result;

      arenas.push({
        address: arenaAddresses[i],
        topic: (get(0) as string) ?? "",
        pot: (get(1) as bigint) ?? 0n,
        phase: (get(2) as ArenaPhase) ?? ArenaPhase.Submission,
        submissionCount: (get(3) as bigint) ?? 0n,
        submissionDeadline: (get(4) as bigint) ?? 0n,
        votingDeadline: (get(5) as bigint) ?? 0n,
        finalized: (get(6) as boolean) ?? false,
      });
    }
  }

  return {
    arenas,
    isLoading: loadingAddresses || loadingDetails,
    factoryReady,
    error: addressesError ?? detailsError ?? null,
  };
}
