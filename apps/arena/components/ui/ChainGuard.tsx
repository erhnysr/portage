"use client";

import { useAccount, useSwitchChain } from "wagmi";
import { arcTestnet } from "@/lib/chain";

export default function ChainGuard({ children }: { children: React.ReactNode }) {
  const { isConnected, chainId } = useAccount();
  const { switchChain, isPending } = useSwitchChain();

  if (!isConnected) return <>{children}</>;

  if (chainId !== arcTestnet.id) {
    return (
      <div className="fixed inset-0 z-50 flex items-center justify-center bg-text/40 backdrop-blur-sm">
        <div className="bg-surface border border-muted rounded-2xl p-8 max-w-sm w-full mx-4 text-center shadow-xl">
          <div className="text-4xl mb-4">⛓️</div>
          <h2 className="font-display text-text text-2xl font-semibold mb-2">
            Wrong Network
          </h2>
          <p className="text-text/60 text-sm mb-6">
            Coliseum runs on Arc Testnet. Switch your wallet to continue.
          </p>
          <button
            onClick={() => switchChain({ chainId: arcTestnet.id })}
            disabled={isPending}
            className="w-full bg-accent hover:bg-accent-light disabled:opacity-50 text-surface font-semibold py-3 rounded-xl transition-colors"
          >
            {isPending ? "Switching…" : "Switch to Arc Testnet"}
          </button>
        </div>
      </div>
    );
  }

  return <>{children}</>;
}
