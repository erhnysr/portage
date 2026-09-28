// Deterministic, server-side display helpers (UTC — never the viewer's locale at build time).

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const pad = (n: number) => String(n).padStart(2, "0");

/** "25 Sep 2026, 18:24 UTC", or "—" when the source has no timestamp. */
export function formatUtc(iso: string | null): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "—";
  return `${pad(d.getUTCDate())} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}, ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())} UTC`;
}

/** 0x1234…abcd — keeps both ends of a hash/address readable. */
export function middle(hex: string, head = 6, tail = 4): string {
  if (hex.length <= head + tail + 2) return hex;
  return `${hex.slice(0, head + 2)}…${hex.slice(-tail)}`;
}

/** Native gas on Arc is USDC with 18 decimals. */
export function formatGasUsdc(wei: string): string {
  const v = BigInt(wei || "0");
  const whole = v / 10n ** 18n;
  const frac = (v % 10n ** 18n).toString().padStart(18, "0").slice(0, 6).replace(/0+$/, "");
  return `${whole}${frac ? "." + frac : ""}`;
}
