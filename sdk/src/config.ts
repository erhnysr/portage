import type { Address } from "viem";

/** Arc Testnet settlement hub. */
export const ARC = {
  chainId: 5042002,
  domain: 26,
  usdc: "0x3600000000000000000000000000000000000000" as Address,
  explorer: "https://explorer.arc.testnet.circle.com",
} as const;

/** Circle Gateway contracts (same address on every chain) + testnet API. */
export const GATEWAY = {
  wallet: "0x0077777d7EBA4688BDeF3E311b846F25870A19B9" as Address,
  minter: "0x0022222ABE238Cc2C7Bb1f21003F0a260052475B" as Address,
  apiTestnet: "https://gateway-api-testnet.circle.com",
} as const;

/** Portage v0.1 contracts, deployed + wired on Arc Testnet (2026-07-20). */
export const PORTAGE_ARC_TESTNET = {
  appRegistry: "0xb803bF100F5CEb71dcC6Db20f8586A7A0901BB67" as Address,
  ledger: "0xEEc603760483B0689B76fb3780eE7edc2E1661b4" as Address,
  payoutEngine: "0xA9Ebe9fC146F6Bdb2FF5A688017eb496C56F66e0" as Address,
  router: "0x9eacb164e5B9D3D24b1A87437668B2245169eD4B" as Address,
  // Redeployed 2026-07-21 with the B1 change (executeMintWithMeta/hashMetaBinding); Router rewired.
  mintForwarder: "0x65473aF9a6006C20C100F6dBA174657b8D88aaed" as Address,
} as const;

/** Supported source chains for consolidation (CCTP/Gateway domains + local USDC). */
export const SOURCE_CHAINS = {
  arcTestnet: { domain: 26, usdc: "0x3600000000000000000000000000000000000000" as Address },
  baseSepolia: { domain: 6, usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as Address },
  ethereumSepolia: { domain: 0, usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as Address },
  arbitrumSepolia: { domain: 3, usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d" as Address },
  avalancheFuji: { domain: 1, usdc: "0x5425890298aed601595a70ab815c96711a31bc65" as Address },
} as const;

export type SourceChain = keyof typeof SOURCE_CHAINS;

export function sourceChainDomain(chain: SourceChain): number {
  return SOURCE_CHAINS[chain].domain;
}

export function sourceChainUsdc(chain: SourceChain): Address {
  return SOURCE_CHAINS[chain].usdc;
}
