import Link from "next/link";
import VerdictSeal from "@/components/ui/VerdictSeal";

const COLUMNS: { heading: string; links: { label: string; href: string; external?: boolean }[] }[] = [
  {
    heading: "Protocol",
    links: [
      { label: "Arenas", href: "/arenas" },
      { label: "Rounds", href: "/#rounds" },
      { label: "Reputation", href: "/#reputation" },
    ],
  },
  {
    heading: "Developers",
    links: [
      { label: "Contracts", href: "https://github.com/erhnysr/coliseum", external: true },
      { label: "ArenaFactory", href: "https://testnet.arcscan.app", external: true },
      { label: "Audits", href: "https://github.com/erhnysr/coliseum", external: true },
    ],
  },
  {
    heading: "Community",
    links: [
      { label: "Discord", href: "https://discord.com", external: true },
      { label: "X", href: "https://x.com/Erhnyasar", external: true },
      { label: "Mirror", href: "https://mirror.xyz", external: true },
    ],
  },
];

export default function Footer() {
  return (
    <footer className="border-t border-muted/60 mt-24">
      <div className="max-w-6xl mx-auto px-6 py-16 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-12">
        <div className="lg:col-span-1">
          <div className="flex items-center gap-2.5 mb-4">
            <VerdictSeal size={28} dashed dot />
            <span className="font-display text-xl font-semibold tracking-[0.15em] text-text">
              COLISEUM
            </span>
          </div>
          <p className="text-text/55 text-sm leading-relaxed max-w-[16rem]">
            Verdicts by stake and reputation. Deployed on Arc.
          </p>
        </div>

        {COLUMNS.map((col) => (
          <div key={col.heading}>
            <h3 className="font-mono text-xs uppercase tracking-[0.2em] text-text/45 mb-5">
              {col.heading}
            </h3>
            <ul className="space-y-3">
              {col.links.map((link) => (
                <li key={link.label}>
                  {link.external ? (
                    <a
                      href={link.href}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="text-text/80 hover:text-accent transition-colors"
                    >
                      {link.label}
                    </a>
                  ) : (
                    <Link href={link.href} className="text-text/80 hover:text-accent transition-colors">
                      {link.label}
                    </Link>
                  )}
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>

      <div className="border-t border-muted/60">
        <div className="max-w-6xl mx-auto px-6 py-6 flex flex-col sm:flex-row items-center justify-between gap-3 font-mono text-xs uppercase tracking-[0.15em] text-text/45">
          <span>© 2026 Coliseum</span>
          <span>Arc · USDC Settlement</span>
        </div>
      </div>
    </footer>
  );
}
