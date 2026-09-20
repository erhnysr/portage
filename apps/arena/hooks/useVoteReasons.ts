"use client";

import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";
import { ARENA_ABI } from "@/lib/contracts";
import { arcTestnet } from "@/lib/chain";

export type VoteReason = {
  submissionId: number;
  voter: `0x${string}`;
  reason: string;
};

// Arc's RPC caps eth_getLogs at a 10,000-block range, so a single
// fromBlock:0 → latest query always 413s. Votes can only occur between
// submissionDeadline and votingDeadline, so we binary-search those
// timestamps to block numbers and scan that bounded range in ≤10k windows.
const MAX_RANGE = 10_000n;
// Safety cap for pathologically long arenas (~5M blocks of scanning).
const MAX_WINDOWS = 500;

/**
 * Reads vote reasons off-chain from the Arena `Voted` event logs.
 * Reasons are event-only (never stored in contract state), so this is the
 * canonical way to surface them — an interim indexer until a dedicated one exists.
 */
export function useVoteReasons(
  arenaAddress: `0x${string}` | undefined,
  submissionDeadline: bigint | undefined,
  votingDeadline: bigint | undefined,
) {
  const publicClient = usePublicClient({ chainId: arcTestnet.id });
  const [reasons, setReasons] = useState<VoteReason[]>([]);
  const [isLoading, setIsLoading] = useState(false);

  useEffect(() => {
    if (
      !arenaAddress ||
      !publicClient ||
      submissionDeadline === undefined ||
      votingDeadline === undefined
    ) {
      return;
    }
    let cancelled = false;

    // Smallest block number in [lo, hi] whose timestamp >= targetTs.
    // If no block reaches targetTs (target in the future), returns hi.
    async function blockAtOrAfter(targetTs: bigint, lo: bigint, hi: bigint): Promise<bigint> {
      let result = hi;
      while (lo <= hi) {
        const mid = lo + (hi - lo) / 2n;
        const block = await publicClient!.getBlock({ blockNumber: mid });
        if (block.timestamp >= targetTs) {
          result = mid;
          hi = mid - 1n;
        } else {
          lo = mid + 1n;
        }
      }
      return result;
    }

    async function load() {
      setIsLoading(true);
      try {
        const latestBlock = await publicClient!.getBlock({ blockTag: "latest" });
        const latest = latestBlock.number!;

        // Bound the scan to the voting window. Run both searches in parallel.
        const [fromBlock, toBlock] = await Promise.all([
          blockAtOrAfter(submissionDeadline!, 0n, latest),
          latestBlock.timestamp < votingDeadline!
            ? Promise.resolve(latest) // voting still open → scan up to the tip
            : blockAtOrAfter(votingDeadline!, 0n, latest),
        ]);

        const collected: VoteReason[] = [];
        let windows = 0;
        for (let start = fromBlock; start <= toBlock; start += MAX_RANGE) {
          if (cancelled) return;
          if (++windows > MAX_WINDOWS) {
            console.warn(
              `useVoteReasons: reached ${MAX_WINDOWS}-window cap; some vote reasons may be missing. Use a dedicated indexer.`,
            );
            break;
          }
          const end = start + MAX_RANGE - 1n > toBlock ? toBlock : start + MAX_RANGE - 1n;
          const logs = await publicClient!.getContractEvents({
            address: arenaAddress!,
            abi: ARENA_ABI,
            eventName: "Voted",
            fromBlock: start,
            toBlock: end,
          });
          for (const log of logs) {
            collected.push({
              submissionId: Number(log.args.submissionId ?? 0n),
              voter: (log.args.voter ?? "0x") as `0x${string}`,
              reason: (log.args.reason ?? "") as string,
            });
          }
        }

        if (!cancelled) setReasons(collected);
      } catch (err) {
        // Surface the failure instead of silently showing nothing.
        console.warn("useVoteReasons: failed to load vote reasons", err);
        if (!cancelled) setReasons([]);
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    }

    load();
    return () => {
      cancelled = true;
    };
  }, [arenaAddress, publicClient, submissionDeadline, votingDeadline]);

  return { reasons, isLoading };
}
