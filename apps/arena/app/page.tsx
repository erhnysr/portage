import Link from "next/link";
import VerdictSeal from "@/components/ui/VerdictSeal";

const ROUNDS = [
  {
    numeral: "I",
    label: "Create",
    title: "Open the arena",
    desc: "State the topic, the prize pool and the two deadlines. The factory deploys your arena contract.",
  },
  {
    numeral: "II",
    label: "Submit",
    title: "Enter the field",
    desc: "Pay the arena's fixed submission fee and register your entry. The contract holds it until the verdict is finalized.",
  },
  {
    numeral: "III",
    label: "Vote",
    title: "Judgement on record",
    desc: "Each vote costs a fixed stake and carries a written reason, stored on-chain beside the voter's address.",
  },
  {
    numeral: "IV",
    label: "Seal",
    title: "Verdict finalized",
    desc: "Once voting ends the arena is finalized, the tally is permanent, and a seal is minted to the winner's soulbound record.",
  },
];

const STATS = [
  { label: "Arenas Deployed", value: "—", sub: "ArenaFactory" },
  { label: "Total USDC Staked", value: "—", sub: "Escrow Balance" },
  { label: "Verdicts Sealed", value: "—", sub: "ReputationNFT" },
  { label: "Network", value: "Arc", sub: "Awaiting Read", display: true },
];

const SAMPLE_ARENAS = [
  { id: "ARENA-0X4F1C", status: "voting", title: "Best onboarding flow for a first-time Arc wallet", action: "Cast a vote" },
  { id: "ARENA-0X9AB7", status: "submission", title: "Redesign the protocol docs landing page", action: "Submit entry" },
  { id: "ARENA-0X2D30", status: "voting", title: "Sharpest audit write-up of the escrow module", action: "Cast a vote" },
  { id: "ARENA-0X77E5", status: "sealed", title: "Which fee model should the factory adopt at launch?", action: "View result" },
  { id: "ARENA-0XC1A8", status: "submission", title: "Name and mark for the next release cycle", action: "Submit entry" },
  { id: "ARENA-0X08BF", status: "sealed", title: "Most useful public dashboard built on ArenaFactory", action: "View result" },
] as const;

const REP_ROWS = [
  { label: "Verdicts won", value: "seal minted", tone: "accent" },
  { label: "Votes cast", value: "tallied on-chain", tone: "accent" },
  { label: "Transferable", value: "never", tone: "oxblood" },
] as const;

export default function Home() {
  return (
    <div className="flex flex-col">
      {/* ───────────────────────── Hero ───────────────────────── */}
      <section className="max-w-6xl mx-auto w-full px-6 pt-16 pb-20 md:pt-24 md:pb-28 grid lg:grid-cols-2 gap-12 items-center">
        <div>
          <div className="inline-flex items-center gap-2 bg-surface border border-muted/70 text-text/70 font-mono text-xs uppercase tracking-[0.2em] px-3.5 py-1.5 rounded-full mb-8">
            <span className="h-2 w-2 rounded-full bg-accent-secondary" />
            Live on Arc
          </div>

          <h1 className="font-display text-6xl md:text-7xl font-semibold tracking-tight text-text leading-[0.95] mb-8">
            Judgement,
            <br />
            held in public.
          </h1>

          <p className="text-lg text-text/70 max-w-xl leading-relaxed mb-10">
            Coliseum is an on-chain judging market. Open an arena, pay a fixed
            submission fee, and let staked votes decide. Every vote and its
            stated reason is written on-chain, and the finalized verdict is
            sealed into a soulbound record.
          </p>

          <div className="flex flex-col sm:flex-row gap-4 mb-12">
            <Link
              href="/arenas"
              className="bg-accent hover:bg-accent-light text-surface font-semibold px-8 py-4 rounded-xl transition-colors text-center"
            >
              Browse arenas
            </Link>
            <Link
              href="/create"
              className="bg-surface hover:border-accent border border-muted text-text font-semibold px-8 py-4 rounded-xl transition-colors text-center"
            >
              Create an arena
            </Link>
          </div>

          <div className="flex flex-wrap gap-x-8 gap-y-2 text-sm font-semibold text-text/80">
            <span>Non-custodial escrow</span>
            <span>USDC settlement</span>
            <span>Soulbound reputation</span>
          </div>
        </div>

        <div className="flex justify-center lg:justify-end">
          <VerdictSeal size={420} ticks dashed label="Verdict" sublabel="Sealed">
            IV
          </VerdictSeal>
        </div>
      </section>

      {/* ───────────────────────── Stats bar ───────────────────────── */}
      <section className="border-y border-muted/60 bg-surface">
        <div className="max-w-6xl mx-auto grid grid-cols-2 lg:grid-cols-4 divide-x divide-y lg:divide-y-0 divide-muted/60">
          {STATS.map((s) => (
            <div key={s.label} className="px-6 py-8">
              <div className="font-mono text-xs uppercase tracking-[0.18em] text-text/45 mb-4">
                {s.label}
              </div>
              <div
                className={`${s.display ? "font-display text-4xl font-semibold" : "text-4xl font-light"} text-text mb-3`}
              >
                {s.value}
              </div>
              <div className="font-mono text-xs uppercase tracking-[0.12em] text-accent">
                {s.sub}
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* ───────────────────────── Four rounds ───────────────────────── */}
      <section id="rounds" className="max-w-6xl mx-auto w-full px-6 py-24">
        <div className="grid md:grid-cols-2 gap-8 items-start mb-14">
          <h2 className="font-display text-5xl font-semibold tracking-tight text-text leading-[1.0]">
            Four rounds,
            <br />
            one verdict.
          </h2>
          <p className="text-text/60 text-lg leading-relaxed md:pt-2 md:max-w-sm md:justify-self-end">
            The order is enforced by contract. Nothing settles early, and
            nothing settles twice.
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 rounded-2xl border border-muted/70 bg-surface overflow-hidden divide-y md:divide-y-0 md:divide-x divide-muted/70">
          {ROUNDS.map((r) => (
            <div key={r.numeral} className="p-8">
              <div className="flex items-start justify-between mb-8">
                <span className="font-display text-5xl font-semibold text-accent leading-none">
                  {r.numeral}
                </span>
                <VerdictSeal size={30} dashed dot />
              </div>
              <div className="font-mono text-xs uppercase tracking-[0.2em] text-text/45 mb-3">
                {r.label}
              </div>
              <h3 className="font-display text-xl font-semibold text-text mb-3">
                {r.title}
              </h3>
              <p className="text-text/60 text-sm leading-relaxed">{r.desc}</p>
            </div>
          ))}
        </div>
      </section>

      {/* ───────────────────────── Arenas in session ───────────────────────── */}
      <section className="max-w-6xl mx-auto w-full px-6 pb-24">
        <p className="font-mono text-sm text-accent mb-3">Reading from ArenaFactory</p>
        <div className="flex items-end justify-between mb-10">
          <h2 className="font-display text-5xl font-semibold tracking-tight text-text">
            Arenas in session
          </h2>
          <Link
            href="/arenas"
            className="font-mono text-sm uppercase tracking-[0.15em] text-accent hover:text-accent-light underline underline-offset-4 whitespace-nowrap"
          >
            View all →
          </Link>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {SAMPLE_ARENAS.map((a) => {
            const sealed = a.status === "sealed";
            return (
              <Link
                key={a.id}
                href="/arenas"
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
                    {a.id}
                  </span>
                  {!sealed && (
                    <span className="font-mono text-[11px] uppercase tracking-[0.15em] text-accent border border-accent/40 rounded-full px-3 py-1">
                      {a.status}
                    </span>
                  )}
                </div>

                <h3 className="font-display text-xl font-semibold text-text leading-snug mb-6 min-h-[3.5rem]">
                  {a.title}
                </h3>

                <div className="border-t border-muted/60 pt-5 grid grid-cols-2 gap-4 mb-6">
                  <div>
                    <div className="font-mono text-[11px] uppercase tracking-[0.12em] text-text/45 mb-1.5">
                      Pot Escrowed
                    </div>
                    <div className="text-lg text-text">— USDC</div>
                  </div>
                  <div>
                    <div className="font-mono text-[11px] uppercase tracking-[0.12em] text-text/45 mb-1.5">
                      Entries
                    </div>
                    <div className="text-lg text-text">—</div>
                  </div>
                </div>

                <div className="flex items-center justify-between">
                  <span className="font-mono text-[11px] uppercase tracking-[0.12em] text-text/45">
                    {sealed ? "Verdict Sealed" : "On-chain Deadline"}
                  </span>
                  <span className="border border-muted text-text font-semibold text-sm px-4 py-2 rounded-lg">
                    {a.action}
                  </span>
                </div>
              </Link>
            );
          })}
        </div>
      </section>

      {/* ───────────────────────── Reputation ───────────────────────── */}
      <section id="reputation" className="border-y border-muted/60 bg-surface">
        <div className="max-w-6xl mx-auto w-full px-6 py-24 grid lg:grid-cols-2 gap-16 items-center">
          <div>
            <p className="font-mono text-sm text-accent mb-4">ReputationNFT</p>
            <h2 className="font-display text-5xl font-semibold tracking-tight text-text mb-6">
              A record you cannot sell.
            </h2>
            <p className="text-lg text-text/70 leading-relaxed max-w-lg mb-10">
              Every verdict you win stamps a seal onto your soulbound token. It
              is non-transferable by design — a public record of what you have
              won, not an asset you can sell.
            </p>

            <div className="border border-muted/70 rounded-xl overflow-hidden divide-y divide-muted/60 max-w-lg">
              {REP_ROWS.map((row) => (
                <div key={row.label} className="flex items-center justify-between px-5 py-4">
                  <span className="text-text">{row.label}</span>
                  <span
                    className={`font-semibold ${row.tone === "oxblood" ? "text-accent-secondary" : "text-accent"}`}
                  >
                    {row.value}
                  </span>
                </div>
              ))}
            </div>
          </div>

          <div className="rounded-2xl border border-muted/70 bg-bg p-10 flex flex-col items-center">
            <VerdictSeal size={300} dashed label="Soulbound" sublabel="Verdicts">
              XII
            </VerdictSeal>
            <div className="w-full flex items-center justify-between mt-8 font-mono text-xs uppercase tracking-[0.15em] text-text/45">
              <span>ERC-5192</span>
              <span>Non-transferable</span>
            </div>
          </div>
        </div>
      </section>

      {/* ───────────────────────── Closing CTA ───────────────────────── */}
      <section className="max-w-3xl mx-auto w-full px-6 py-28 text-center flex flex-col items-center">
        <VerdictSeal size={56} dashed dot dotVariant="oxblood" className="mb-10" />
        <h2 className="font-display text-5xl md:text-6xl font-semibold tracking-tight text-text mb-6">
          Bring a question worth settling.
        </h2>
        <p className="text-lg text-text/60 mb-10">
          Deploy an arena in one transaction. The crowd does the rest.
        </p>
        <div className="flex flex-col sm:flex-row gap-4">
          <Link
            href="/create"
            className="bg-accent hover:bg-accent-light text-surface font-semibold px-8 py-4 rounded-xl transition-colors"
          >
            Create an arena
          </Link>
          <a
            href="https://github.com/erhnysr/coliseum"
            target="_blank"
            rel="noopener noreferrer"
            className="bg-surface hover:border-accent border border-muted text-text font-semibold px-8 py-4 rounded-xl transition-colors"
          >
            Read the contracts
          </a>
        </div>
      </section>
    </div>
  );
}
