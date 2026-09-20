type VerdictSealProps = {
  /** Big center content — a Roman numeral, count, glyph, etc. */
  children?: React.ReactNode;
  /** Small caps label above the center content. */
  label?: string;
  /** Small caps label below the center content. */
  sublabel?: string;
  /** Pixel diameter. */
  size?: number;
  /** Oxblood variant, used sparingly for settled/final verdicts. */
  variant?: "accent" | "oxblood";
  /** Render the elaborate outer tick + colored-arc ring (hero medallion). */
  ticks?: boolean;
  /** Dashed inner hairline ring. */
  dashed?: boolean;
  /** Render only a center dot (logo mark / punctuation seal). */
  dot?: boolean;
  /** Color of the center dot, independent of the rings. Defaults to `variant`. */
  dotVariant?: "accent" | "oxblood";
  className?: string;
};

/**
 * Signature circular "verdict seal / medallion" motif.
 * Pure SVG + CSS — no image assets, scales crisply at any size.
 * Center labels use Space Mono; the big numeral uses Fraunces (display).
 */
export default function VerdictSeal({
  children,
  label,
  sublabel,
  size = 120,
  variant = "accent",
  ticks = false,
  dashed = false,
  dot = false,
  dotVariant,
  className = "",
}: VerdictSealProps) {
  const stroke = variant === "oxblood" ? "var(--accent-secondary)" : "var(--accent)";
  const alt = variant === "oxblood" ? "var(--accent)" : "var(--accent-secondary)";
  const dotColor = (dotVariant ?? variant) === "oxblood" ? "var(--accent-secondary)" : "var(--accent)";

  const tickCount = 72;
  const tickMarks = ticks
    ? Array.from({ length: tickCount }, (_, i) => {
        const a = (i / tickCount) * Math.PI * 2;
        const inner = 90;
        const outer = i % 6 === 0 ? 82 : 86;
        return {
          x1: 100 + Math.cos(a) * inner,
          y1: 100 + Math.sin(a) * inner,
          x2: 100 + Math.cos(a) * outer,
          y2: 100 + Math.sin(a) * outer,
        };
      })
    : [];

  return (
    <div
      className={`relative inline-flex items-center justify-center ${className}`}
      style={{ width: size, height: size }}
    >
      <svg viewBox="0 0 200 200" width={size} height={size} className="absolute inset-0">
        {/* Faint outermost ring */}
        <circle cx="100" cy="100" r="96" fill="none" stroke={stroke} strokeWidth="1" opacity="0.25" />

        {ticks && (
          <>
            {tickMarks.map((t, i) => (
              <line
                key={i}
                x1={t.x1}
                y1={t.y1}
                x2={t.x2}
                y2={t.y2}
                stroke={stroke}
                strokeWidth="0.75"
                opacity="0.35"
              />
            ))}
            {/* Colored arc accents */}
            <circle cx="100" cy="100" r="88" fill="none" stroke={stroke} strokeWidth="2.5"
              strokeLinecap="round" strokeDasharray="34 519" transform="rotate(-70 100 100)" />
            <circle cx="100" cy="100" r="88" fill="none" stroke={stroke} strokeWidth="2.5"
              strokeLinecap="round" strokeDasharray="22 531" transform="rotate(120 100 100)" />
            <circle cx="100" cy="100" r="88" fill="none" stroke={alt} strokeWidth="2.5"
              strokeLinecap="round" strokeDasharray="14 539" transform="rotate(30 100 100)" />
            <circle cx="100" cy="100" r="88" fill="none" stroke={alt} strokeWidth="2.5"
              strokeLinecap="round" strokeDasharray="12 541" transform="rotate(200 100 100)" />
          </>
        )}

        {/* Solid inner ring */}
        <circle cx="100" cy="100" r={ticks ? 64 : 72} fill={ticks ? "var(--surface)" : "none"}
          stroke={stroke} strokeWidth="1.5" />

        {/* Dashed hairline ring */}
        {dashed && (
          <circle cx="100" cy="100" r={ticks ? 54 : 60} fill="none" stroke={stroke}
            strokeWidth="1" strokeDasharray="2 4" opacity="0.7" />
        )}

        {dot && <circle cx="100" cy="100" r="6" fill={dotColor} />}
      </svg>

      {/* Center face */}
      {!dot && (
        <div className="relative flex flex-col items-center justify-center text-center leading-none"
          style={{ color: stroke }}>
          {label && (
            <span className="font-mono uppercase tracking-[0.25em]"
              style={{ fontSize: size * 0.06 }}>{label}</span>
          )}
          {children != null && (
            <span className="font-display font-semibold"
              style={{ fontSize: size * 0.24, margin: `${size * 0.05}px 0` }}>{children}</span>
          )}
          {sublabel && (
            <span className="font-mono uppercase tracking-[0.25em]"
              style={{ fontSize: size * 0.06 }}>{sublabel}</span>
          )}
        </div>
      )}
    </div>
  );
}
