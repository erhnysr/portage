"use client";

import { useCountdown } from "@/hooks/useCountdown";
import { ArenaPhase } from "@/lib/contracts";

type Props = {
  phase: ArenaPhase;
  submissionDeadline: bigint;
  votingDeadline: bigint;
  finalized?: boolean;
};

function resolvePhase(phase: ArenaPhase, subDeadline: bigint, voteDeadline: bigint): ArenaPhase {
  const now = BigInt(Math.floor(Date.now() / 1000));
  if (phase === ArenaPhase.Submission && subDeadline > 0n && now >= subDeadline) {
    return voteDeadline > 0n && now >= voteDeadline ? ArenaPhase.Ended : ArenaPhase.Voting;
  }
  if (phase === ArenaPhase.Voting && voteDeadline > 0n && now >= voteDeadline) {
    return ArenaPhase.Ended;
  }
  return phase;
}

/**
 * Compact deadline read-out for the arena hero stats row.
 * Renders a label + value pair (no outer padding — the parent cell owns spacing).
 */
export default function PhaseTimer({ phase, submissionDeadline, votingDeadline, finalized }: Props) {
  const subCountdown = useCountdown(submissionDeadline);
  const voteCountdown = useCountdown(votingDeadline);
  const resolved = resolvePhase(phase, submissionDeadline, votingDeadline);

  let label = "Voting Ends";
  let value = "—";
  if (resolved === ArenaPhase.Submission) {
    label = "Submissions Close";
    value = subCountdown.label;
  } else if (resolved === ArenaPhase.Voting) {
    label = "Voting Ends";
    value = voteCountdown.label;
  } else {
    label = "Status";
    value = finalized ? "Verdict Sealed" : "Awaiting Finalization";
  }

  return (
    <>
      <div className="font-mono text-xs uppercase tracking-[0.15em] text-text/45 mb-2">{label}</div>
      <div className="text-accent text-lg font-medium tabular-nums">{value}</div>
    </>
  );
}
