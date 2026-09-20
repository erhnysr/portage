"use client";

import { useArena, canSubmit, canVote } from "@/hooks/useArena";
import { ArenaPhase } from "@/lib/contracts";
import { formatUsdc, USDC_ADDRESS, SUBMISSION_FEE, VOTE_STAKE } from "@/lib/usdc";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { ARENA_ABI, ERC20_APPROVE_ABI, MAX_VOTE_REASON } from "@/lib/contracts";
import { useState } from "react";
import PhaseTimer from "./PhaseTimer";
import Leaderboard from "./Leaderboard";
import VoteReasons from "./VoteReasons";
import TxStatus from "@/components/ui/TxStatus";

type Props = { address: `0x${string}` };
type Detail = NonNullable<ReturnType<typeof useArena>["detail"]>;

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function resolvePhase(phase: ArenaPhase, subDeadline: bigint, voteDeadline: bigint): ArenaPhase {
  const now = BigInt(Math.floor(Date.now() / 1000));
  if (phase === ArenaPhase.Submission && subDeadline > 0n && now >= subDeadline) {
    return voteDeadline > 0n && now >= voteDeadline ? ArenaPhase.Ended : ArenaPhase.Voting;
  }
  if (phase === ArenaPhase.Voting && voteDeadline > 0n && now >= voteDeadline) return ArenaPhase.Ended;
  return phase;
}

const ROUND_LABEL: Record<ArenaPhase, string> = {
  [ArenaPhase.Submission]: "Round II of IV",
  [ArenaPhase.Voting]: "Round III of IV",
  [ArenaPhase.Ended]: "Round IV of IV",
};

// ── Hero phase pill ──────────────────────────────────────────────
function PhasePill({ phase, sealed }: { phase: ArenaPhase; sealed: boolean }) {
  if (sealed) {
    return (
      <span className="font-mono text-xs uppercase tracking-[0.18em] text-accent-secondary bg-accent-secondary/10 rounded-full px-3 py-1">
        Sealed
      </span>
    );
  }
  const map: Record<ArenaPhase, { label: string; live?: boolean }> = {
    [ArenaPhase.Submission]: { label: "Submission" },
    [ArenaPhase.Voting]: { label: "Voting", live: true },
    [ArenaPhase.Ended]: { label: "Ended" },
  };
  const { label, live } = map[phase];
  return (
    <span className="inline-flex items-center gap-2 font-mono text-xs uppercase tracking-[0.18em] text-accent bg-accent-tint rounded-full px-3 py-1">
      {live && <span className="h-1.5 w-1.5 rounded-full bg-accent" />}
      {label}
    </span>
  );
}

function StatCell({ label, value }: { label: string; value: string }) {
  return (
    <div className="px-6 py-5">
      <div className="font-mono text-xs uppercase tracking-[0.15em] text-text/45 mb-2">{label}</div>
      <div className="text-lg font-medium text-text tabular-nums">{value}</div>
    </div>
  );
}

// ── Inline vote confirmation (voting phase, per-entry) ───────────
function VoteConfirm({
  arenaAddress,
  detail,
  selectedId,
  onClose,
}: {
  arenaAddress: `0x${string}`;
  detail: Detail;
  selectedId: number;
  onClose: () => void;
}) {
  const { isConnected } = useAccount();
  const [voteReason, setVoteReason] = useState("");
  const { ok, reason } = canVote(detail, isConnected);

  const { writeContract: approve, data: approveTxHash, isPending: approvePending } = useWriteContract();
  const { writeContract: vote, data: voteTxHash, isPending: votePending } = useWriteContract();
  const { isLoading: approveConfirming, isSuccess: approveConfirmed } =
    useWaitForTransactionReceipt({ hash: approveTxHash });
  const { isLoading: voteConfirming, isSuccess: voteConfirmed } =
    useWaitForTransactionReceipt({ hash: voteTxHash });

  const needsApprove = detail.usdcAllowance < VOTE_STAKE;
  const target = detail.submissions[selectedId];

  function handleApprove() {
    approve({
      address: USDC_ADDRESS,
      abi: ERC20_APPROVE_ABI,
      functionName: "approve",
      args: [arenaAddress, VOTE_STAKE],
    });
  }

  function handleVote() {
    vote({
      address: arenaAddress,
      abi: ARENA_ABI,
      functionName: "vote",
      args: [BigInt(selectedId), voteReason.trim()],
    });
  }

  return (
    <div className="rounded-2xl border border-accent/40 bg-surface p-6">
      <div className="flex items-start justify-between gap-4 mb-4">
        <div className="min-w-0">
          <h3 className="font-display text-xl font-semibold text-text">Cast your vote</h3>
          <p className="text-text/55 text-sm mt-0.5 truncate">
            Entry #{selectedId + 1} · {target ? target.contentRef : ""}
          </p>
        </div>
        <button onClick={onClose} className="text-text/40 hover:text-text text-sm">
          Change
        </button>
      </div>

      {!ok ? (
        <p className="text-text/55 text-sm">{reason}</p>
      ) : (
        <div className="space-y-3">
          <textarea
            placeholder="Why this entry? (optional, public — recorded on-chain)"
            value={voteReason}
            onChange={(e) => setVoteReason(e.target.value.slice(0, MAX_VOTE_REASON))}
            rows={2}
            maxLength={MAX_VOTE_REASON}
            className="w-full bg-bg border border-muted text-text text-sm rounded-xl px-4 py-3 placeholder-text/40 focus:outline-none focus:border-accent resize-none"
          />
          <div className="flex items-center justify-between">
            <p className="text-text/50 text-xs">Stake: 0.05 USDC — rebated if winner</p>
            <p className="text-text/40 text-[11px]">{voteReason.length}/{MAX_VOTE_REASON}</p>
          </div>

          {needsApprove && !approveConfirmed ? (
            <button
              onClick={handleApprove}
              disabled={approvePending || approveConfirming}
              className="w-full bg-accent-secondary hover:opacity-90 disabled:opacity-50 text-surface font-semibold py-3 rounded-xl text-sm transition-colors"
            >
              {approvePending || approveConfirming ? "Approving…" : "1. Approve 0.05 USDC"}
            </button>
          ) : (
            <button
              onClick={handleVote}
              disabled={votePending || voteConfirming}
              className="w-full bg-accent hover:bg-accent-light disabled:opacity-50 text-surface font-semibold py-3 rounded-xl text-sm transition-colors"
            >
              {votePending || voteConfirming ? "Voting…" : "Cast vote"}
            </button>
          )}

          <TxStatus
            hash={approveTxHash ?? voteTxHash}
            isPending={approvePending || votePending}
            isConfirming={approveConfirming || voteConfirming}
            isConfirmed={voteConfirmed}
          />
        </div>
      )}
    </div>
  );
}

// ── Sidebar: Your Position (stats + contextual primary action) ───
function YourPosition({ arenaAddress, detail }: { arenaAddress: `0x${string}`; detail: Detail }) {
  const { isConnected } = useAccount();
  const phase = resolvePhase(detail.phase, detail.submissionDeadline, detail.votingDeadline);

  const [contentRef, setContentRef] = useState("");
  const submitOk = canSubmit(detail, isConnected);

  const { writeContract: approve, data: approveTxHash, isPending: approvePending } = useWriteContract();
  const { writeContract: submit, data: submitTxHash, isPending: submitPending } = useWriteContract();
  const { writeContract: action, data: actionTxHash, isPending: actionPending } = useWriteContract();

  const { isLoading: approveConfirming, isSuccess: approveConfirmed } =
    useWaitForTransactionReceipt({ hash: approveTxHash });
  const { isLoading: submitConfirming, isSuccess: submitConfirmed } =
    useWaitForTransactionReceipt({ hash: submitTxHash });
  const { isLoading: actionConfirming, isSuccess: actionConfirmed } =
    useWaitForTransactionReceipt({ hash: actionTxHash });

  const needsApprove = detail.usdcAllowance < SUBMISSION_FEE;
  const canFinalize = detail.phase === ArenaPhase.Ended && !detail.finalized && isConnected;
  const canWithdraw = detail.finalized && detail.pendingWithdraw > 0n && isConnected;

  const feesPaid =
    (detail.hasSubmitted ? SUBMISSION_FEE : 0n) + (detail.hasVoted ? VOTE_STAKE : 0n);

  const rows: { label: string; value: string; tone?: "accent" | "oxblood" }[] = [
    { label: "Fees paid", value: isConnected ? `${formatUsdc(feesPaid)} USDC` : "— USDC" },
    { label: "Entries submitted", value: isConnected ? (detail.hasSubmitted ? "1" : "0") : "—" },
    {
      label: "Vote cast",
      value: detail.hasVoted ? "cast" : "not cast",
      tone: detail.hasVoted ? "accent" : "oxblood",
    },
  ];

  return (
    <div className="rounded-2xl border border-muted/70 bg-surface p-6">
      <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-text/45 mb-5">Your Position</h2>

      <div className="border border-muted/60 rounded-xl divide-y divide-muted/60 mb-5">
        {rows.map((r) => (
          <div key={r.label} className="flex items-center justify-between px-4 py-3.5">
            <span className="text-text/80 text-sm">{r.label}</span>
            <span
              className={`text-sm font-medium ${
                r.tone === "oxblood"
                  ? "text-accent-secondary font-mono"
                  : r.tone === "accent"
                    ? "text-accent font-mono"
                    : "text-text"
              }`}
            >
              {r.value}
            </span>
          </div>
        ))}
      </div>

      {/* Contextual primary action */}
      {canWithdraw ? (
        <>
          <p className="text-text/70 text-sm mb-3">
            You have{" "}
            <span className="text-accent font-semibold">{formatUsdc(detail.pendingWithdraw)} USDC</span>{" "}
            pending.
          </p>
          <button
            onClick={() => action({ address: arenaAddress, abi: ARENA_ABI, functionName: "withdraw" })}
            disabled={actionPending || actionConfirming}
            className="w-full bg-accent hover:bg-accent-light disabled:opacity-50 text-surface font-semibold py-3.5 rounded-xl text-sm transition-colors"
          >
            {actionPending || actionConfirming ? "Withdrawing…" : "Withdraw winnings"}
          </button>
          <TxStatus hash={actionTxHash} isPending={actionPending} isConfirming={actionConfirming} isConfirmed={actionConfirmed} />
        </>
      ) : canFinalize ? (
        <>
          <p className="text-text/60 text-sm mb-3">Voting ended. Finalize to seal the verdict and distribute prizes.</p>
          <button
            onClick={() => action({ address: arenaAddress, abi: ARENA_ABI, functionName: "finalize" })}
            disabled={actionPending || actionConfirming}
            className="w-full bg-accent hover:bg-accent-light disabled:opacity-50 text-surface font-semibold py-3.5 rounded-xl text-sm transition-colors"
          >
            {actionPending || actionConfirming ? "Finalizing…" : "Finalize arena"}
          </button>
          <TxStatus hash={actionTxHash} isPending={actionPending} isConfirming={actionConfirming} isConfirmed={actionConfirmed} />
        </>
      ) : phase === ArenaPhase.Submission ? (
        submitOk.ok ? (
          <div className="space-y-3">
            <input
              type="text"
              placeholder="IPFS hash or URL (e.g. ipfs://Qm…)"
              value={contentRef}
              onChange={(e) => setContentRef(e.target.value)}
              className="w-full bg-bg border border-muted text-text text-sm rounded-xl px-4 py-3 placeholder-text/40 focus:outline-none focus:border-accent"
            />
            <p className="text-text/50 text-xs">Fee: 0.10 USDC → added to prize pool</p>
            {needsApprove && !approveConfirmed ? (
              <button
                onClick={() =>
                  approve({ address: USDC_ADDRESS, abi: ERC20_APPROVE_ABI, functionName: "approve", args: [arenaAddress, SUBMISSION_FEE] })
                }
                disabled={approvePending || approveConfirming}
                className="w-full bg-accent-secondary hover:opacity-90 disabled:opacity-50 text-surface font-semibold py-3.5 rounded-xl text-sm transition-colors"
              >
                {approvePending || approveConfirming ? "Approving…" : "1. Approve 0.10 USDC"}
              </button>
            ) : (
              <button
                onClick={() => {
                  if (!contentRef.trim()) return;
                  submit({ address: arenaAddress, abi: ARENA_ABI, functionName: "submit", args: [contentRef.trim()] });
                }}
                disabled={submitPending || submitConfirming || !contentRef.trim()}
                className="w-full bg-accent hover:bg-accent-light disabled:opacity-50 text-surface font-semibold py-3.5 rounded-xl text-sm transition-colors"
              >
                {submitPending || submitConfirming ? "Submitting…" : "Submit entry"}
              </button>
            )}
            <TxStatus
              hash={approveTxHash ?? submitTxHash}
              isPending={approvePending || submitPending}
              isConfirming={approveConfirming || submitConfirming}
              isConfirmed={submitConfirmed}
            />
          </div>
        ) : (
          <div className="w-full text-center border border-muted/70 rounded-xl py-3.5 font-mono text-xs uppercase tracking-[0.15em] text-text/45">
            {submitOk.reason}
          </div>
        )
      ) : (
        <div className="w-full text-center border border-muted/70 rounded-xl py-3.5 font-mono text-xs uppercase tracking-[0.15em] text-text/45">
          {detail.finalized ? "Verdict Sealed" : phase === ArenaPhase.Voting ? "Submissions Closed" : "Voting Closed"}
        </div>
      )}

      <p className="text-text/45 text-xs leading-relaxed mt-4">
        Submission fees and vote stakes are held by the arena contract and paid out only once the
        verdict is finalized.
      </p>
    </div>
  );
}

// ── Sidebar: Rules ───────────────────────────────────────────────
function RulesBox({ detail }: { detail: Detail }) {
  const phase = resolvePhase(detail.phase, detail.submissionDeadline, detail.votingDeadline);
  const totalVotes = detail.submissions.reduce((acc, s) => acc + s.votes, 0n);
  const PHASE_TEXT: Record<ArenaPhase, string> = {
    [ArenaPhase.Submission]: "Submission",
    [ArenaPhase.Voting]: "Voting",
    [ArenaPhase.Ended]: detail.finalized ? "Sealed" : "Ended",
  };
  const rows = [
    { label: "Submission fee", value: `${formatUsdc(SUBMISSION_FEE)} USDC` },
    { label: "Vote stake", value: `${formatUsdc(VOTE_STAKE)} USDC` },
    { label: "Submissions", value: detail.submissionCount.toString() },
    { label: "Votes cast", value: totalVotes.toString() },
    { label: "Phase", value: PHASE_TEXT[phase] },
  ];
  return (
    <div className="rounded-2xl border border-muted/70 bg-surface p-6">
      <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-text/45 mb-5">Rules</h2>
      <div className="divide-y divide-muted/50">
        {rows.map((r) => (
          <div key={r.label} className="flex items-center justify-between py-3">
            <span className="text-text/70 text-sm">{r.label}</span>
            <span className="text-text text-sm font-medium tabular-nums">{r.value}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Sidebar: Contract ────────────────────────────────────────────
function ContractBox({ address }: { address: `0x${string}` }) {
  return (
    <div className="rounded-2xl border border-muted/70 bg-surface p-6">
      <h2 className="font-mono text-xs uppercase tracking-[0.2em] text-text/45 mb-4">Contract</h2>
      <p className="font-mono text-xs text-text/70 break-all mb-4">{address}</p>
      <a
        href={`https://testnet.arcscan.app/address/${address}`}
        target="_blank"
        rel="noopener noreferrer"
        className="font-mono text-xs uppercase tracking-[0.15em] text-accent hover:text-accent-light"
      >
        View on Explorer →
      </a>
    </div>
  );
}

// ── How votes are counted (static explainer) ─────────────────────
function HowVotesCounted() {
  return (
    <div className="rounded-2xl border border-muted/70 bg-surface p-8">
      <h2 className="font-display text-2xl font-semibold text-text mb-3">How votes are counted</h2>
      <p className="text-text/65 text-sm leading-relaxed max-w-xl mb-5">
        Each vote costs a fixed stake and adds one to a submission&apos;s tally. The share shown on
        every entry is simply its votes over all votes cast in this arena.
      </p>
      <div className="rounded-xl bg-bg border border-muted/60 px-5 py-4 font-mono text-sm text-text">
        share = votes / Σ votes
      </div>
      <p className="text-text/45 text-xs leading-relaxed mt-5">
        Reputation-weighted voting is a proposed mechanism for a later version. This contract does
        not implement it.
      </p>
    </div>
  );
}

// ── Main component ───────────────────────────────────────────────
export default function ArenaDetail({ address }: Props) {
  const { detail, isLoading } = useArena(address);
  const [selectedId, setSelectedId] = useState<number | null>(null);

  if (isLoading) {
    return (
      <div className="animate-pulse grid lg:grid-cols-3 gap-6">
        <div className="lg:col-span-2 space-y-6">
          <div className="h-64 bg-muted/40 rounded-2xl" />
          <div className="h-40 bg-muted/40 rounded-2xl" />
        </div>
        <div className="h-80 bg-muted/40 rounded-2xl" />
      </div>
    );
  }

  if (!detail) {
    return <p className="text-text/50 text-sm">Arena not found or not yet deployed.</p>;
  }

  const phase = resolvePhase(detail.phase, detail.submissionDeadline, detail.votingDeadline);
  const sealed = detail.finalized;
  const totalVotes = detail.submissions.reduce((acc, s) => acc + s.votes, 0n);

  return (
    <div className="grid lg:grid-cols-3 gap-6 items-start">
      {/* LEFT */}
      <div className="lg:col-span-2 space-y-6">
        {/* Hero */}
        <div className="rounded-2xl border border-muted/70 bg-surface p-8">
          <div className="flex items-center gap-4 mb-5">
            <PhasePill phase={phase} sealed={sealed} />
            <span className="font-mono text-xs uppercase tracking-[0.18em] text-text/45">
              {ROUND_LABEL[phase]}
            </span>
          </div>

          <h1 className="font-display text-4xl md:text-5xl font-semibold text-text leading-[1.05] mb-3">
            {detail.topic}
          </h1>
          <p className="text-text/55 text-sm">
            Opened by <span className="font-mono text-text/70">{shortAddr(detail.creator)}</span>
          </p>

          <div className="mt-8 border border-muted/60 rounded-xl grid grid-cols-2 sm:grid-cols-4 divide-x divide-y sm:divide-y-0 divide-muted/60">
            <StatCell label="Pot Escrowed" value={`${formatUsdc(detail.pot)} USDC`} />
            <StatCell label="Entries" value={detail.submissionCount.toString()} />
            <StatCell label="Voters" value={totalVotes.toString()} />
            <div className="px-6 py-5">
              <PhaseTimer
                phase={detail.phase}
                submissionDeadline={detail.submissionDeadline}
                votingDeadline={detail.votingDeadline}
                finalized={detail.finalized}
              />
            </div>
          </div>
        </div>

        {/* Entries */}
        <div>
          <div className="flex items-end justify-between mb-5">
            <h2 className="font-display text-3xl font-semibold text-text">
              {sealed ? "Results" : "Entries"}
            </h2>
            <span className="font-mono text-xs uppercase tracking-[0.15em] text-text/45">
              Sorted by votes
            </span>
          </div>
          <Leaderboard
            submissions={detail.submissions}
            winners={detail.winners}
            phase={detail.phase}
            pot={detail.pot}
            finalized={sealed}
            votable={phase === ArenaPhase.Voting}
            onVote={(id) => setSelectedId(id)}
            selectedId={selectedId}
          />
        </div>

        {/* Inline vote confirmation */}
        {phase === ArenaPhase.Voting && selectedId !== null && (
          <VoteConfirm
            arenaAddress={address}
            detail={detail}
            selectedId={selectedId}
            onClose={() => setSelectedId(null)}
          />
        )}

        <HowVotesCounted />

        <VoteReasons
          arenaAddress={address}
          submissions={detail.submissions}
          submissionDeadline={detail.submissionDeadline}
          votingDeadline={detail.votingDeadline}
        />
      </div>

      {/* RIGHT sidebar */}
      <div className="space-y-6">
        <YourPosition arenaAddress={address} detail={detail} />
        <RulesBox detail={detail} />
        <ContractBox address={address} />
      </div>
    </div>
  );
}
