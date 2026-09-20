"use client";

import Link from "next/link";
import { ArenaPhase } from "@/lib/contracts";
import { formatUsdc } from "@/lib/usdc";
import { useCountdown } from "@/hooks/useCountdown";
import VerdictSeal from "@/components/ui/VerdictSeal";
import type { ArenaInfo } from "@/hooks/useArenas";

// Derive phase from current time when on-chain data is stale (wagmi cache lag)
function effectivePhase(phase: ArenaPhase, subDeadline: bigint, voteDeadline: bigint): ArenaPhase {
  const now = BigInt(Math.floor(Date.now() / 1000));
  if (phase === ArenaPhase.Submission && subDeadline > 0n && now >= subDeadline) {
    return voteDeadline > 0n && now >= voteDeadline ? ArenaPhase.Ended : ArenaPhase.Voting;
  }
  if (phase === ArenaPhase.Voting && voteDeadline > 0n && now >= voteDeadline) {
    return ArenaPhase.Ended;
  }
  return phase;
}

const PHASE_LABEL: Record<ArenaPhase, string> = {
  [ArenaPhase.Submission]: "Submission",
  [ArenaPhase.Voting]: "Voting",
  [ArenaPhase.Ended]: "Ended",
};

const PHASE_ACTION: Record<ArenaPhase, string> = {
  [ArenaPhase.Submission]: "Submit entry",
  [ArenaPhase.Voting]: "Cast a vote",
  [ArenaPhase.Ended]: "View result",
};

function Countdown({ deadline }: { deadline: bigint }) {
  const { label, expired } = useCountdown(deadline);
  if (expired) return <span className="text-text/40">—</span>;
  return <span className="text-text tabular-nums">{label}</span>;
}

export default function ArenaCard({ arena }: { arena: ArenaInfo }) {
  const phase = effectivePhase(arena.phase, arena.submissionDeadline, arena.votingDeadline);
  const phaseDeadline =
    phase === ArenaPhase.Submission ? arena.submissionDeadline : arena.votingDeadline;
  // "Sealed" means finalize() was called on-chain — NOT merely past the voting deadline.
  const sealed = arena.finalized;
  // Voting deadline has passed but the verdict hasn't been finalized yet.
  const endedAwaiting = phase === ArenaPhase.Ended && !arena.finalized;
  const shortId = `ARENA-${arena.address.slice(2, 6).toUpperCase()}`;

  return (
    <Link
      href={`/arenas/${arena.address}`}
      className={`relative block rounded-2xl border bg-surface p-6 transition-colors hover:border-accent ${
        sealed ? "border-accent/40" : "border-muted/70"
      }`}
    >
      {sealed && (
        <div className="absolute -top-4 -right-4 rotate-[-8deg]">
          <VerdictSeal size={72} variant="oxblood" dashed label="Verdict" sublabel="Sealed" />
        </div>
      )}

      <div className="flex items-center justify-between mb-5">
        <span className="font-mono text-xs uppercase tracking-[0.12em] text-text/45">
          {shortId}
        </span>
        {!sealed && (
          <span className="font-mono text-[11px] uppercase tracking-[0.15em] text-accent border border-accent/40 rounded-full px-3 py-1">
            {PHASE_LABEL[phase]}
          </span>
        )}
      </div>

      <h3 className="font-display text-xl font-semibold text-text leading-snug mb-6 line-clamp-2 min-h-[3.5rem]">
        {arena.topic}
      </h3>

      <div className="border-t border-muted/60 pt-5 grid grid-cols-2 gap-4 mb-6">
        <div>
          <div className="font-mono text-[11px] uppercase tracking-[0.12em] text-text/45 mb-1.5">
            Pot Escrowed
          </div>
          <div className="text-lg text-text">{formatUsdc(arena.pot)} USDC</div>
        </div>
        <div>
          <div className="font-mono text-[11px] uppercase tracking-[0.12em] text-text/45 mb-1.5">
            Entries
          </div>
          <div className="text-lg text-text">{arena.submissionCount.toString()}</div>
        </div>
      </div>

      <div className="flex items-center justify-between">
        <div className="font-mono text-[11px] uppercase tracking-[0.12em] text-text/45">
          {sealed ? (
            "Verdict Sealed"
          ) : endedAwaiting ? (
            "Ended · Awaiting Finalization"
          ) : (
            <>
              On-chain Deadline{" "}
              <span className="normal-case tracking-normal text-text/70">
                · <Countdown deadline={phaseDeadline} />
              </span>
            </>
          )}
        </div>
        <span className="border border-muted text-text font-semibold text-sm px-4 py-2 rounded-lg whitespace-nowrap">
          {PHASE_ACTION[phase]}
        </span>
      </div>
    </Link>
  );
}
