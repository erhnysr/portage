"use client";

import { useVoteReasons } from "@/hooks/useVoteReasons";
import type { ArenaSubmission } from "@/lib/contracts";

type Props = {
  arenaAddress: `0x${string}`;
  submissions: ArenaSubmission[];
  submissionDeadline: bigint;
  votingDeadline: bigint;
};

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export default function VoteReasons({
  arenaAddress,
  submissions,
  submissionDeadline,
  votingDeadline,
}: Props) {
  const { reasons, isLoading } = useVoteReasons(
    arenaAddress,
    submissionDeadline,
    votingDeadline,
  );

  // Only reasons with actual text — empty (opt-out) votes are hidden here
  const withText = reasons.filter((r) => r.reason.trim().length > 0);

  if (isLoading) {
    return (
      <div className="rounded-2xl border border-muted/70 bg-surface p-8">
        <h2 className="font-display text-2xl font-semibold text-text mb-4">Voter Notes</h2>
        <div className="h-16 bg-muted/40 rounded-xl animate-pulse" />
      </div>
    );
  }

  if (withText.length === 0) return null;

  return (
    <div className="rounded-2xl border border-muted/70 bg-surface p-8">
      <h2 className="font-display text-2xl font-semibold text-text mb-1">
        Voter Notes{" "}
        <span className="text-text/40 font-normal text-base">({withText.length})</span>
      </h2>
      <p className="text-text/55 text-sm mb-6">
        Public reasoning attached to votes, read from on-chain event logs.
      </p>
      <div className="space-y-3">
        {withText.map((r, i) => {
          const target = submissions[r.submissionId];
          return (
            <div
              key={`${r.voter}-${i}`}
              className="p-4 rounded-xl border border-muted/60 bg-bg"
            >
              <div className="flex items-center gap-2 text-xs text-text/45 mb-1.5">
                <span className="font-mono">{shortAddr(r.voter)}</span>
                <span>→</span>
                <span className="text-accent break-all">
                  {target
                    ? target.contentRef
                    : `entry #${r.submissionId + 1}`}
                </span>
              </div>
              <p className="text-text/80 text-sm leading-relaxed break-words">
                {r.reason}
              </p>
            </div>
          );
        })}
      </div>
    </div>
  );
}
