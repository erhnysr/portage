"use client";

import { ArenaPhase, type ArenaSubmission } from "@/lib/contracts";
import { formatUsdc } from "@/lib/usdc";
import VerdictSeal from "@/components/ui/VerdictSeal";

type Props = {
  submissions: ArenaSubmission[];
  winners: readonly [bigint, bigint, bigint]; // 1-indexed IDs, 0 = no winner
  phase: ArenaPhase;
  pot: bigint;
  finalized: boolean;
  /** Show per-entry Vote buttons (voting phase only). */
  votable?: boolean;
  onVote?: (submissionId: number) => void;
  selectedId?: number | null;
};

const SPLIT = [60, 30, 10]; // pot split for 1st / 2nd / 3rd (basis: /100)
const ROMAN = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"];
const numeral = (n: number) => ROMAN[n - 1] ?? String(n);

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

export default function Leaderboard({
  submissions,
  winners,
  pot,
  finalized,
  votable = false,
  onVote,
  selectedId,
}: Props) {
  if (submissions.length === 0) {
    return (
      <div className="rounded-2xl border border-muted/70 bg-surface text-center py-12 text-text/50 text-sm">
        No entries yet.
      </div>
    );
  }

  const totalVotes = submissions.reduce((acc, s) => acc + s.votes, 0n);

  // Sort by votes desc, tiebreak by original index asc (matches contract logic)
  const sorted = [...submissions]
    .map((s, i) => ({ ...s, id: i }))
    .sort((a, b) => {
      const vDiff = Number(b.votes - a.votes);
      if (vDiff !== 0) return vDiff;
      return a.id - b.id;
    });

  // A verdict only exists once finalize() has been called on-chain.
  const isSealed = finalized && winners[0] > 0n;

  return (
    <div className="space-y-4">
      {sorted.map((s, rank) => {
        const winnerSlot = isSealed ? winners.findIndex((w) => w === BigInt(s.id + 1)) : -1;
        const isWinner = winnerSlot !== -1;
        const prize = isWinner ? (pot * BigInt(SPLIT[winnerSlot])) / 100n : null;
        const share =
          totalVotes > 0n ? Math.round(Number((s.votes * 10000n) / totalVotes) / 100) : 0;
        const isTop = rank === 0;
        const selected = selectedId === s.id;

        return (
          <div
            key={s.id}
            className={`relative flex items-center gap-5 rounded-2xl border bg-surface px-6 py-5 transition-colors ${
              isWinner
                ? "border-accent-secondary/40"
                : selected
                  ? "border-accent"
                  : isTop
                    ? "border-accent/40"
                    : "border-muted/70"
            }`}
          >
            <VerdictSeal
              size={56}
              variant={isWinner ? "oxblood" : "accent"}
              className={isTop && !isWinner ? "rounded-full bg-accent-tint" : ""}
            >
              {numeral(rank + 1)}
            </VerdictSeal>

            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-3 mb-1.5">
                <span className="font-mono text-xs text-text/45">{shortAddr(s.submitter)}</span>
                <span className="font-mono text-[11px] text-accent border border-accent/40 rounded-full px-2 py-0.5">
                  {s.votes.toString()} {s.votes === 1n ? "vote" : "votes"}
                </span>
              </div>
              <h3 className="font-display text-lg font-semibold text-text truncate">
                {s.contentRef || `Entry #${s.id + 1}`}
              </h3>
              <div className="mt-3 h-1.5 w-full rounded-full bg-muted/40 overflow-hidden">
                <div
                  className={`h-full rounded-full ${isTop ? "bg-accent" : "bg-text/25"}`}
                  style={{ width: `${share}%` }}
                />
              </div>
            </div>

            <div className="flex-shrink-0 flex flex-col items-end gap-2 w-24">
              <span className="font-display text-2xl font-semibold text-text tabular-nums">
                {share}%
              </span>
              {votable && onVote ? (
                <button
                  onClick={() => onVote(s.id)}
                  className={`text-sm font-semibold px-5 py-2 rounded-lg transition-colors ${
                    selected
                      ? "bg-accent-light text-surface"
                      : "bg-accent hover:bg-accent-light text-surface"
                  }`}
                >
                  Vote
                </button>
              ) : (
                prize !== null && (
                  <span className="text-sm text-accent font-medium">
                    +{formatUsdc(prize)} USDC
                  </span>
                )
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
