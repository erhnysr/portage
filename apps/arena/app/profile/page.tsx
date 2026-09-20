"use client";

import Link from "next/link";
import { useAccount } from "wagmi";
import { useProfile } from "@/hooks/useProfile";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import VerdictSeal from "@/components/ui/VerdictSeal";

const ROMAN = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII"];
const numeral = (n: number) => ROMAN[n - 1] ?? String(n);

function shortAddr(addr: string) {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

function StatCell({
  label,
  value,
  className = "",
}: {
  label: string;
  value: string | number;
  className?: string;
}) {
  return (
    <div className={`px-5 py-4 ${className}`}>
      <div className="font-mono text-xs uppercase tracking-[0.15em] text-text/45 mb-2">{label}</div>
      <div className="text-2xl font-medium text-text tabular-nums">{value}</div>
    </div>
  );
}

export default function ProfilePage() {
  const { address, isConnected } = useAccount();
  const { createdArenas, winRecords, isLoading } = useProfile(address);

  if (!isConnected) {
    return (
      <div className="max-w-md mx-auto px-6 py-24 text-center flex flex-col items-center gap-6">
        <VerdictSeal size={96} dashed dot dotVariant="oxblood" />
        <p className="text-text/70 text-lg">Connect your wallet to view your soulbound record.</p>
        <ConnectButton />
      </div>
    );
  }

  const verdictsWon = winRecords.length;
  const sortedWins = [...winRecords].sort((a, b) => Number(b.timestamp - a.timestamp));

  return (
    <div className="max-w-5xl mx-auto px-6 py-10 space-y-6">
      {/* ── Soulbound Record ── */}
      <section className="rounded-2xl border border-muted/70 bg-surface p-8 md:p-10">
        <div className="grid lg:grid-cols-[1fr_auto] gap-10 items-center">
          <div>
            <p className="font-mono text-xs uppercase tracking-[0.2em] text-accent mb-4">
              Soulbound Record
            </p>
            <h1 className="font-mono text-3xl md:text-4xl font-bold text-text break-all leading-tight mb-4">
              {address}
            </h1>
            <p className="text-text/60 text-sm leading-relaxed max-w-md mb-8">
              Minted on first sealed verdict. Non-transferable — this record follows the address, not
              the wallet holder.
            </p>

            <div className="border border-muted/60 rounded-xl overflow-hidden grid grid-cols-3 max-w-xl">
              <StatCell
                label="Verdicts Won"
                value={isLoading ? "…" : verdictsWon}
                className="border-r border-b border-muted/50"
              />
              <StatCell
                label="Arenas Created"
                value={isLoading ? "…" : createdArenas.length}
                className="border-r border-b border-muted/50"
              />
              <StatCell label="Entries" value="—" className="border-b border-muted/50" />
              <StatCell label="Votes Cast" value="—" className="border-r border-muted/50" />
              <div className="col-span-2 bg-muted/25" />
            </div>
          </div>

          <div className="flex justify-center lg:justify-end">
            <VerdictSeal size={240} dashed label="Soulbound" sublabel="Verdicts">
              {isLoading ? "…" : verdictsWon || "—"}
            </VerdictSeal>
          </div>
        </div>
      </section>

      {/* ── How voting works ── */}
      <section className="rounded-2xl border border-muted/70 bg-surface p-8 md:p-10">
        <h2 className="font-display text-2xl font-semibold text-text mb-3">How voting works</h2>
        <p className="text-text/65 text-sm leading-relaxed max-w-xl mb-6">
          Every vote costs a fixed stake and carries a written reason. Both are permanent, and both
          are attributable to this address.
        </p>
        <div className="rounded-xl bg-bg border border-muted/60 px-5 py-4 font-mono text-sm">
          <span className="text-text">vote = </span>
          <span className="text-accent">VOTE_STAKE</span>
          <span className="text-text"> + </span>
          <span className="text-accent-secondary">public reason</span>
        </div>
      </section>

      {/* ── Seals earned ── */}
      <section>
        <div className="flex items-end justify-between mb-6">
          <h2 className="font-display text-3xl font-semibold text-text">Seals earned</h2>
          <span className="font-mono text-xs uppercase tracking-[0.15em] text-text/45">
            Each win stamps the record
          </span>
        </div>

        {isLoading ? (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            {[...Array(4)].map((_, i) => (
              <div key={i} className="h-56 rounded-2xl border border-muted/70 bg-surface animate-pulse" />
            ))}
          </div>
        ) : sortedWins.length === 0 ? (
          <div className="rounded-2xl border border-muted/70 bg-surface text-center py-16 px-6">
            <p className="text-text/60 text-base mb-3">No seals yet.</p>
            <Link href="/arenas" className="text-accent hover:text-accent-light text-sm transition-colors">
              Browse arenas to win your first verdict →
            </Link>
          </div>
        ) : (
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            {sortedWins.map((rec, i) => (
              <Link
                key={`${rec.arena}-${i}`}
                href={`/arenas/${rec.arena}`}
                className="block rounded-2xl border border-muted/70 bg-surface p-6 transition-colors hover:border-accent"
              >
                <div className="mb-4">
                  <VerdictSeal size={56} variant="oxblood" dashed label="Verdict">
                    {numeral(verdictsWon - i)}
                  </VerdictSeal>
                </div>
                <h3 className="font-display text-lg font-semibold text-text leading-snug mb-6 min-h-[3.5rem]">
                  {rec.category}
                </h3>
                <div className="border-t border-muted/60 pt-4 space-y-2">
                  <div className="flex items-center justify-between">
                    <span className="font-mono text-[11px] uppercase tracking-[0.12em] text-text/45">
                      Arena Pot
                    </span>
                    <span className="font-mono text-sm text-text">— USDC</span>
                  </div>
                  <div className="flex items-center justify-between">
                    <span className="font-mono text-[11px] uppercase tracking-[0.12em] text-text/45">
                      Arena
                    </span>
                    <span className="font-mono text-sm text-text">{shortAddr(rec.arena)}</span>
                  </div>
                </div>
              </Link>
            ))}
          </div>
        )}
      </section>
    </div>
  );
}
