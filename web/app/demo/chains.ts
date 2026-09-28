import { defineChain } from "viem";
import { arbitrumSepolia, avalancheFuji, baseSepolia, sepolia } from "viem/chains";

// Arc Testnet as a wallet sees it. Native gas is USDC; at the EVM level it has 18 decimals
// (the 6-decimal ERC-20 view of USDC lives at 0x3600…0000).
export const arcTestnet = defineChain({
  id: 5042002,
  name: "Arc Testnet",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.arc.network"] } },
  blockExplorers: { default: { name: "Arc explorer", url: "https://explorer.testnet.arc.io" } },
  testnet: true,
});

export type SourceKey = "baseSepolia" | "ethereumSepolia" | "arbitrumSepolia" | "avalancheFuji";

// Gateway source domains the published SDK (0.1.0) knows. Only Base Sepolia has been run
// end to end through Portage; the others are consolidation sources via the same code path.
export const SOURCES: Record<SourceKey, { domain: number; label: string; chain: typeof baseSepolia | typeof sepolia | typeof arbitrumSepolia | typeof avalancheFuji; verified: boolean }> = {
  baseSepolia: { domain: 6, label: "Base Sepolia", chain: baseSepolia, verified: true },
  ethereumSepolia: { domain: 0, label: "Ethereum Sepolia", chain: sepolia, verified: false },
  arbitrumSepolia: { domain: 3, label: "Arbitrum Sepolia", chain: arbitrumSepolia, verified: false },
  avalancheFuji: { domain: 1, label: "Avalanche Fuji", chain: avalancheFuji, verified: false },
};

export const SOURCE_ORDER: SourceKey[] = ["baseSepolia", "ethereumSepolia", "arbitrumSepolia", "avalancheFuji"];

export const EXPLORER_API = "https://explorer.testnet.arc.io/api/v2";
export const FAUCET_URL = "https://faucet.circle.com";
export const APP_REGISTRY = "0xb803bF100F5CEb71dcC6Db20f8586A7A0901BB67" as const;
