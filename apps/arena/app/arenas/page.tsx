import Link from "next/link";
import ArenaList from "@/components/arena/ArenaList";

export default function ArenasPage() {
  return (
    <div className="max-w-6xl mx-auto px-6 py-10">
      <div className="flex items-center justify-between mb-8">
        <h1 className="font-display text-4xl font-semibold tracking-tight text-text">Arenas</h1>
        <Link
          href="/create"
          className="bg-accent hover:bg-accent-light text-surface text-sm font-semibold px-5 py-2.5 rounded-xl transition-colors"
        >
          + Create
        </Link>
      </div>
      <ArenaList />
    </div>
  );
}
