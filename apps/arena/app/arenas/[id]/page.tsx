// Next.js 16: params is a Promise — must be awaited
import Link from "next/link";
import ArenaDetail from "@/components/arena/ArenaDetail";

export default async function ArenaDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;

  // Basic address validation before passing to client component
  const isValidAddress = /^0x[0-9a-fA-F]{40}$/.test(id);

  const shortId = isValidAddress ? `ARENA-${id.slice(2, 6).toUpperCase()}` : id;

  return (
    <div className="max-w-6xl mx-auto px-6 py-10">
      <div className="mb-6 font-mono text-xs uppercase tracking-[0.15em] text-text/45">
        <Link href="/arenas" className="hover:text-accent transition-colors">
          Arenas
        </Link>
        <span className="mx-2">/</span>
        <span className="text-text/70">{shortId}</span>
      </div>

      {isValidAddress ? (
        <ArenaDetail address={id as `0x${string}`} />
      ) : (
        <p className="text-accent-secondary text-sm">
          Invalid arena address: <code>{id}</code>
        </p>
      )}
    </div>
  );
}
