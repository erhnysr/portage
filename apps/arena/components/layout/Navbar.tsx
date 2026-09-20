"use client";

import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import VerdictSeal from "@/components/ui/VerdictSeal";

export default function Navbar() {
  return (
    <header className="sticky top-0 z-40 border-b border-muted/50 bg-bg/85 backdrop-blur-md">
      <div className="max-w-6xl mx-auto px-6 h-20 flex items-center justify-between">
        <Link href="/" className="flex items-center gap-3">
          <VerdictSeal size={30} dashed dot />
          <span className="font-display text-2xl font-semibold tracking-[0.15em] text-text">
            COLISEUM
          </span>
        </Link>

        <nav className="hidden md:flex items-center gap-8 text-[15px] text-text/70">
          <Link href="/arenas" className="text-accent font-medium transition-colors">
            Arenas
          </Link>
          <Link href="/#rounds" className="hover:text-accent transition-colors">
            Rounds
          </Link>
          <Link href="/create" className="hover:text-accent transition-colors">
            Create
          </Link>
          <Link href="/profile" className="hover:text-accent transition-colors">
            Profile
          </Link>
        </nav>

        {/* Custom-styled trigger — RainbowKit connect logic preserved via Custom render prop */}
        <ConnectButton.Custom>
          {({
            account,
            chain,
            openAccountModal,
            openChainModal,
            openConnectModal,
            authenticationStatus,
            mounted,
          }) => {
            const ready = mounted && authenticationStatus !== "loading";
            const connected =
              ready &&
              account &&
              chain &&
              (!authenticationStatus || authenticationStatus === "authenticated");

            return (
              <div
                {...(!ready && {
                  "aria-hidden": true,
                  style: { opacity: 0, pointerEvents: "none", userSelect: "none" },
                })}
              >
                {!connected ? (
                  <button
                    onClick={openConnectModal}
                    className="bg-text hover:bg-text/90 text-bg font-semibold text-sm px-5 py-2.5 rounded-xl transition-colors"
                  >
                    Connect wallet
                  </button>
                ) : chain.unsupported ? (
                  <button
                    onClick={openChainModal}
                    className="bg-accent-secondary hover:opacity-90 text-surface font-semibold text-sm px-5 py-2.5 rounded-xl transition-colors"
                  >
                    Wrong network
                  </button>
                ) : (
                  <div className="flex items-center gap-2">
                    <button
                      onClick={openChainModal}
                      className="hidden sm:flex items-center gap-1.5 bg-surface border border-muted text-text text-sm font-medium px-3 py-2.5 rounded-xl hover:border-accent transition-colors"
                    >
                      {chain.hasIcon && chain.iconUrl && (
                        // eslint-disable-next-line @next/next/no-img-element
                        <img alt={chain.name ?? "Chain"} src={chain.iconUrl} className="h-4 w-4" />
                      )}
                      {chain.name}
                    </button>
                    <button
                      onClick={openAccountModal}
                      className="bg-text hover:bg-text/90 text-bg font-semibold text-sm px-4 py-2.5 rounded-xl transition-colors font-mono"
                    >
                      {account.displayName}
                    </button>
                  </div>
                )}
              </div>
            );
          }}
        </ConnectButton.Custom>
      </div>
    </header>
  );
}
