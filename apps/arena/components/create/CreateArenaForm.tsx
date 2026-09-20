"use client";

import { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { parseEventLogs } from "viem";
import {
  ARENA_FACTORY_ADDRESS,
  ARENA_FACTORY_ABI,
  ERC20_APPROVE_ABI,
  MAX_VOTE_REASON,
} from "@/lib/contracts";
import { USDC_ADDRESS, parseUsdc, formatUsdc, SUBMISSION_FEE, VOTE_STAKE } from "@/lib/usdc";
import TxStatus from "@/components/ui/TxStatus";
import VerdictSeal from "@/components/ui/VerdictSeal";

function toDatetimeLocal(offsetHours: number) {
  const d = new Date(Date.now() + offsetHours * 3600 * 1000);
  return d.toISOString().slice(0, 16);
}

function toUnixSeconds(datetimeLocal: string): bigint {
  return BigInt(Math.floor(new Date(datetimeLocal).getTime() / 1000));
}

// Present a datetime-local string as a human-readable deadline.
function fmtDeadline(datetimeLocal: string): string {
  if (!datetimeLocal) return "—";
  const d = new Date(datetimeLocal);
  if (isNaN(d.getTime())) return "—";
  return d.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

type FormState = {
  topic: string;
  prizePool: string;
  subDeadline: string;
  voteDeadline: string;
};

type FieldError = Partial<Record<keyof FormState, string>>;

export default function CreateArenaForm() {
  const router = useRouter();
  const { address, isConnected } = useAccount();

  const [form, setForm] = useState<FormState>({
    topic: "",
    prizePool: "0",
    subDeadline: toDatetimeLocal(24),
    voteDeadline: toDatetimeLocal(48),
  });
  const [errors, setErrors] = useState<FieldError>({});
  const [step, setStep] = useState<"form" | "approve" | "create" | "done">("form");

  // Presentation-only: day-based windows drive the datetime-local strings above,
  // and an off-chain judging brief (no contract field — not persisted on-chain).
  const [subDays, setSubDays] = useState(1);
  const [voteDays, setVoteDays] = useState(1);
  const [brief, setBrief] = useState("");

  const prizePoolUsdc = parseUsdc(form.prizePool || "0");
  const needsApprove = prizePoolUsdc > 0n;

  // Approve tx
  const {
    writeContract: writeApprove,
    data: approveTxHash,
    isPending: approvePending,
    error: approveError,
  } = useWriteContract();

  const { isLoading: approveConfirming, isSuccess: approveConfirmed } =
    useWaitForTransactionReceipt({ hash: approveTxHash });

  // CreateArena tx
  const {
    writeContract: writeCreate,
    data: createTxHash,
    isPending: createPending,
    error: createError,
  } = useWriteContract();

  const {
    isLoading: createConfirming,
    isSuccess: createConfirmed,
    data: createReceipt,
  } = useWaitForTransactionReceipt({ hash: createTxHash });

  // After approve confirmed → auto-advance to create step
  useEffect(() => {
    if (approveConfirmed && step === "approve") {
      setStep("create");
    }
  }, [approveConfirmed, step]);

  // After create confirmed → extract arena address and redirect
  useEffect(() => {
    if (createConfirmed && createReceipt && step === "create") {
      try {
        const logs = parseEventLogs({
          abi: ARENA_FACTORY_ABI,
          eventName: "ArenaCreated",
          logs: createReceipt.logs as Parameters<typeof parseEventLogs>[0]["logs"],
        });
        const arenaAddress = (logs[0] as { args: { arena: `0x${string}` } }).args.arena;
        setStep("done");
        setTimeout(() => router.push(`/arenas/${arenaAddress}`), 1200);
      } catch {
        // fallback: just redirect to arenas list
        setStep("done");
        setTimeout(() => router.push("/arenas"), 1200);
      }
    }
  }, [createConfirmed, createReceipt, step, router]);

  function validate(): boolean {
    const next: FieldError = {};
    const subTs = toUnixSeconds(form.subDeadline);
    const voteTs = toUnixSeconds(form.voteDeadline);
    const now = BigInt(Math.floor(Date.now() / 1000));

    if (!form.topic.trim()) next.topic = "Topic is required.";
    if (form.topic.length > 120) next.topic = "Topic must be ≤ 120 characters.";

    const pool = parseFloat(form.prizePool || "0");
    if (isNaN(pool) || pool < 0) {
      next.prizePool = "Must be a positive number.";
    } else if (pool > 0 && parseUsdc(form.prizePool || "0") < SUBMISSION_FEE) {
      next.prizePool = "Minimum prize pool is 0.10 USDC.";
    }

    if (subTs <= now) next.subDeadline = "Submission deadline must be in the future.";
    if (voteTs <= subTs) next.voteDeadline = "Voting deadline must be after submission deadline.";

    setErrors(next);
    return Object.keys(next).length === 0;
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!validate()) return;

    if (needsApprove) {
      setStep("approve");
      writeApprove({
        address: USDC_ADDRESS,
        abi: ERC20_APPROVE_ABI,
        functionName: "approve",
        args: [ARENA_FACTORY_ADDRESS, prizePoolUsdc],
      });
    } else {
      setStep("create");
      sendCreate();
    }
  }

  function sendCreate() {
    writeCreate({
      address: ARENA_FACTORY_ADDRESS,
      abi: ARENA_FACTORY_ABI,
      functionName: "createArena",
      args: [
        form.topic.trim(),
        prizePoolUsdc,
        toUnixSeconds(form.subDeadline),
        toUnixSeconds(form.voteDeadline),
      ],
    });
  }

  // Once approve confirmed (useEffect sets step="create"), trigger create
  useEffect(() => {
    if (step === "create" && !createTxHash && !createPending) {
      // Only auto-fire if we just came from approve step
      if (approveConfirmed && needsApprove) sendCreate();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step, approveConfirmed]);

  function set(key: keyof FormState) {
    return (e: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>) => {
      setForm((f) => ({ ...f, [key]: e.target.value }));
      setErrors((err) => ({ ...err, [key]: undefined }));
    };
  }

  // Day-based windows → recompute the datetime-local deadlines (form shape unchanged).
  function daysFromNow(days: number) {
    return new Date(Date.now() + days * 86400 * 1000).toISOString().slice(0, 16);
  }
  function updateSubDays(days: number) {
    const d = Math.max(1, days || 1);
    setSubDays(d);
    setForm((f) => ({
      ...f,
      subDeadline: daysFromNow(d),
      voteDeadline: daysFromNow(d + voteDays),
    }));
    setErrors((err) => ({ ...err, subDeadline: undefined, voteDeadline: undefined }));
  }
  function updateVoteDays(days: number) {
    const d = Math.max(1, days || 1);
    setVoteDays(d);
    setForm((f) => ({ ...f, voteDeadline: daysFromNow(subDays + d) }));
    setErrors((err) => ({ ...err, voteDeadline: undefined }));
  }

  const factoryReady = ARENA_FACTORY_ADDRESS.length > 2;
  const txError = approveError ?? createError;
  const anyPending = approvePending || approveConfirming || createPending || createConfirming;

  const inputBase =
    "w-full bg-bg border text-text text-sm rounded-xl px-4 py-3 placeholder-text/40 focus:outline-none transition-colors";
  const inputOk = "border-muted focus:border-accent";
  const inputErr = "border-accent-secondary focus:border-accent-secondary";

  const fixedRows = [
    { label: "Submission fee", value: `${formatUsdc(SUBMISSION_FEE)} USDC` },
    { label: "Vote stake", value: `${formatUsdc(VOTE_STAKE)} USDC` },
    { label: "Reason length limit", value: `${MAX_VOTE_REASON} chars` },
    { label: "Vote tally", value: "One per address · unweighted" },
  ];

  const summaryRows = [
    { label: "Prize pool", value: `${form.prizePool || "0"} USDC` },
    { label: "Submission deadline", value: fmtDeadline(form.subDeadline) },
    { label: "Voting deadline", value: fmtDeadline(form.voteDeadline) },
    { label: "Settlement asset", value: "USDC" },
    { label: "Reputation token", value: "ReputationNFT · ERC-5192" },
  ];

  return (
    <form onSubmit={handleSubmit} className="space-y-6">
      {/* ── The Question ── */}
      <section className="rounded-2xl border border-muted/70 bg-surface p-8">
        <h2 className="font-display text-2xl font-semibold text-text mb-1">The Question</h2>
        <p className="text-text/55 text-sm mb-6">What is the arena judging?</p>

        <label className="block text-sm font-medium text-text/80 mb-2">
          Title <span className="text-accent-secondary">*</span>
        </label>
        <input
          type="text"
          value={form.topic}
          onChange={set("topic")}
          placeholder="Best onboarding flow for a first-time Arc wallet"
          maxLength={120}
          className={`${inputBase} ${errors.topic ? inputErr : inputOk}`}
        />
        <div className="flex justify-between mt-1 mb-6">
          {errors.topic && <p className="text-accent-secondary text-xs">{errors.topic}</p>}
          <p className="text-text/40 text-xs ml-auto">{form.topic.length}/120</p>
        </div>

        <label className="block text-sm font-medium text-text/80 mb-2">Judging brief</label>
        <textarea
          value={brief}
          onChange={(e) => setBrief(e.target.value)}
          rows={3}
          placeholder="How should voters judge entries? e.g. clarity, time-to-first-transaction, handling a user who has never held USDC."
          className={`${inputBase} ${inputOk} resize-none`}
        />
        <p className="text-text/40 text-xs mt-1">
          Optional context for voters. Not stored on-chain in this version.
        </p>
      </section>

      {/* ── Prize Pool ── */}
      <section className="rounded-2xl border border-muted/70 bg-surface p-8">
        <h2 className="font-display text-2xl font-semibold text-text mb-1">Prize Pool</h2>
        <p className="text-text/55 text-sm mb-6">
          Seed the pot. Submission fees are added to it automatically.
        </p>
        <div className="relative">
          <input
            type="number"
            value={form.prizePool}
            onChange={set("prizePool")}
            min="0"
            step="0.01"
            placeholder="0.00"
            className={`${inputBase} pr-16 ${errors.prizePool ? inputErr : inputOk}`}
          />
          <span className="absolute right-4 top-1/2 -translate-y-1/2 font-mono text-text/45 text-sm">
            USDC
          </span>
        </div>
        {errors.prizePool && <p className="text-accent-secondary text-xs mt-1">{errors.prizePool}</p>}
      </section>

      {/* ── Windows ── */}
      <section className="rounded-2xl border border-muted/70 bg-surface p-8">
        <h2 className="font-display text-2xl font-semibold text-text mb-1">Windows</h2>
        <p className="text-text/55 text-sm mb-6">
          How long each round stays open. Voting begins when submissions close.
        </p>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div>
            <label className="block text-sm font-medium text-text/80 mb-2">Submissions open for</label>
            <div className="relative">
              <input
                type="number"
                min="1"
                value={subDays}
                onChange={(e) => updateSubDays(Number(e.target.value))}
                className={`${inputBase} pr-16 ${errors.subDeadline ? inputErr : inputOk}`}
              />
              <span className="absolute right-4 top-1/2 -translate-y-1/2 font-mono text-text/45 text-sm">
                days
              </span>
            </div>
            {errors.subDeadline && (
              <p className="text-accent-secondary text-xs mt-1">{errors.subDeadline}</p>
            )}
          </div>
          <div>
            <label className="block text-sm font-medium text-text/80 mb-2">Voting open for</label>
            <div className="relative">
              <input
                type="number"
                min="1"
                value={voteDays}
                onChange={(e) => updateVoteDays(Number(e.target.value))}
                className={`${inputBase} pr-16 ${errors.voteDeadline ? inputErr : inputOk}`}
              />
              <span className="absolute right-4 top-1/2 -translate-y-1/2 font-mono text-text/45 text-sm">
                days
              </span>
            </div>
            {errors.voteDeadline && (
              <p className="text-accent-secondary text-xs mt-1">{errors.voteDeadline}</p>
            )}
          </div>
        </div>
      </section>

      {/* ── Fixed by the Contract ── */}
      <section className="rounded-2xl border border-muted/70 bg-surface p-8">
        <h2 className="font-display text-2xl font-semibold text-text mb-1">Fixed by the Contract</h2>
        <p className="text-text/55 text-sm mb-6">
          These are enforced on-chain and cannot be set per-arena.
        </p>
        <div className="border border-muted/60 rounded-xl divide-y divide-muted/50">
          {fixedRows.map((r) => (
            <div key={r.label} className="flex items-center justify-between px-5 py-3.5">
              <span className="text-text/70 text-sm">{r.label}</span>
              <span className="font-mono text-sm text-text tabular-nums">{r.value}</span>
            </div>
          ))}
        </div>
      </section>

      {/* ── Deploy Summary ── */}
      <section className="rounded-2xl border border-muted/70 bg-surface p-8">
        <div className="flex items-start gap-6 mb-8">
          <VerdictSeal size={80} dashed label="Round" sublabel="of IV">
            I
          </VerdictSeal>
          <div>
            <h2 className="font-display text-2xl font-semibold text-text mb-1">Deploy Summary</h2>
            <p className="text-text/55 text-sm">
              {form.topic.trim() || "Your arena topic will appear here."}
            </p>
          </div>
        </div>

        <div className="border border-muted/60 rounded-xl divide-y divide-muted/50 mb-6">
          {summaryRows.map((r) => (
            <div key={r.label} className="flex items-center justify-between px-5 py-3.5">
              <span className="text-text/70 text-sm">{r.label}</span>
              <span className="font-mono text-sm text-text tabular-nums">{r.value}</span>
            </div>
          ))}
        </div>

        {/* CTA — write flow unchanged */}
        {!isConnected ? (
          <div className="text-center border border-muted/70 rounded-xl py-3.5 font-mono text-xs uppercase tracking-[0.15em] text-text/45">
            Connect your wallet to deploy
          </div>
        ) : !factoryReady ? (
          <div className="text-center border border-muted/70 rounded-xl py-3.5 font-mono text-xs uppercase tracking-[0.15em] text-text/45">
            Contract not yet deployed to Arc Testnet
          </div>
        ) : step === "done" ? (
          <div className="bg-accent-tint border border-accent/40 rounded-xl p-4 text-center">
            <p className="text-accent font-semibold">Arena created! Redirecting…</p>
          </div>
        ) : (
          <div className="space-y-3">
            {needsApprove && (step === "approve" || step === "create") && (
              <div className="flex items-center gap-3 font-mono text-xs uppercase tracking-[0.12em] text-text/45">
                <span className={step === "approve" ? "text-accent-secondary font-semibold" : "text-accent"}>
                  {approveConfirmed ? "✓" : "1."} Approve USDC
                </span>
                <span className="text-muted">→</span>
                <span className={step === "create" ? "text-accent font-semibold" : ""}>
                  2. Deploy Arena
                </span>
              </div>
            )}

            <button
              type="submit"
              disabled={anyPending || !address || step === "approve" || step === "create"}
              className="w-full bg-accent hover:bg-accent-light disabled:opacity-50 disabled:cursor-not-allowed text-surface font-semibold py-3.5 rounded-xl text-sm transition-colors"
            >
              {anyPending
                ? step === "approve"
                  ? "Approving USDC…"
                  : "Deploying arena…"
                : needsApprove
                  ? "Approve & deploy arena"
                  : "Deploy arena"}
            </button>

            <TxStatus
              hash={approveTxHash ?? createTxHash}
              isPending={approvePending || createPending}
              isConfirming={approveConfirming || createConfirming}
              isConfirmed={createConfirmed}
              error={txError}
            />
          </div>
        )}
      </section>

      {/* ── Immutable warning ── */}
      <section className="rounded-2xl border border-accent-secondary/40 bg-accent-secondary/5 p-6">
        <h3 className="font-display text-lg font-semibold text-accent-secondary mb-2">
          Immutable at deploy
        </h3>
        <p className="text-text/70 text-sm leading-relaxed">
          The topic, prize pool and both deadlines are written into the arena contract at deploy and
          cannot be edited afterward. Review the summary above before you deploy.
        </p>
      </section>
    </form>
  );
}
