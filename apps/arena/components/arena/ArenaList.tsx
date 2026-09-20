"use client";

import { useArenas } from "@/hooks/useArenas";
import { ArenaPhase } from "@/lib/contracts";
import ArenaCard from "./ArenaCard";
import { useState } from "react";

type Filter = "all" | "active" | "ended";

function SkeletonCard() {
  return (
    <div className="bg-surface border border-muted/70 rounded-2xl p-6 animate-pulse">
      <div className="flex items-start justify-between mb-5">
        <div className="h-4 w-24 bg-muted/50 rounded" />
        <div className="h-6 w-20 bg-muted/50 rounded-full" />
      </div>
      <div className="h-5 w-3/4 bg-muted/50 rounded mb-2" />
      <div className="h-5 w-1/2 bg-muted/50 rounded mb-8" />
      <div className="flex justify-between">
        <div className="h-8 w-24 bg-muted/50 rounded" />
        <div className="h-8 w-16 bg-muted/50 rounded" />
      </div>
    </div>
  );
}

export default function ArenaList() {
  const { arenas, isLoading, factoryReady, error } = useArenas();
  const [filter, setFilter] = useState<Filter>("all");

  const filtered = arenas.filter((a) => {
    if (filter === "active") return a.phase !== ArenaPhase.Ended && !a.finalized;
    if (filter === "ended") return a.phase === ArenaPhase.Ended || a.finalized;
    return true;
  });

  // Sort: active first, then by votingDeadline desc
  const sorted = [...filtered].sort((a, b) => {
    if (a.phase !== ArenaPhase.Ended && b.phase === ArenaPhase.Ended) return -1;
    if (a.phase === ArenaPhase.Ended && b.phase !== ArenaPhase.Ended) return 1;
    return Number(b.votingDeadline - a.votingDeadline);
  });

  if (error) {
    return (
      <div className="text-center py-20">
        <p className="text-accent-secondary text-sm font-mono">Error: {error.message}</p>
      </div>
    );
  }

  if (!factoryReady) {
    return (
      <div className="text-center py-20">
        <p className="text-text/50 text-sm">
          Contract not deployed yet. Deploy to Arc Testnet to see arenas.
        </p>
      </div>
    );
  }

  return (
    <div>
      {/* Filter tabs */}
      <div className="flex gap-2 mb-8">
        {(["all", "active", "ended"] as Filter[]).map((f) => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            className={`text-sm font-medium px-4 py-2 rounded-xl border transition-colors capitalize ${
              filter === f
                ? "bg-accent border-accent text-surface"
                : "bg-surface border-muted/70 text-text/60 hover:text-accent hover:border-accent"
            }`}
          >
            {f}
          </button>
        ))}
      </div>

      {isLoading ? (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {[...Array(6)].map((_, i) => <SkeletonCard key={i} />)}
        </div>
      ) : sorted.length === 0 ? (
        <div className="text-center py-20">
          <p className="text-text/50 text-sm">
            {filter === "all" ? "No arenas yet." : `No ${filter} arenas.`}
          </p>
        </div>
      ) : (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {sorted.map((arena) => (
            <ArenaCard key={arena.address} arena={arena} />
          ))}
        </div>
      )}
    </div>
  );
}
