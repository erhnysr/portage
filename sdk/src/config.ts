import type { Address } from "viem";

/**
 * Network-keyed configuration. Every Arc/Gateway/Portage fact is resolved from one
 * `NetworkConfig` selected by name, so the SDK can target Arc Testnet today and Arc mainnet
 * once Circle publishes it — without any consumer hardcoding a testnet address.
 *
 * Prefer {getNetwork} + the returned `NetworkConfig` over the deprecated flat exports
 * (`ARC`, `GATEWAY`, `PORTAGE_ARC_TESTNET`, `SOURCE_CHAINS`), which remain only for 0.1.x
 * compatibility and always point at Arc Testnet.
 */

export type NetworkName = "arcTestnet" | "arcMainnet";

/** Default network when a caller does not specify one. */
export const DEFAULT_NETWORK: NetworkName = "arcTestnet";

/** Sentinel for a network whose Circle-published values are not available yet. */
export const PENDING = Symbol("portage:pending-network");
export type Pending = typeof PENDING;

/** Arc settlement-hub chain facts. */
export interface ArcNetwork {
  chainId: number;
  /** CCTP / Circle Gateway domain. */
  domain: number;
  /** Native USDC (gas token) on Arc. */
  usdc: Address;
  /** Blockscout explorer base for transactions, e.g. `${explorerTx}<hash>`. */
  explorerTx: string;
  /** Blockscout explorer base for addresses, e.g. `${explorerAddress}<addr>`. */
  explorerAddress: string;
}

/** Circle Gateway contracts (same address on every chain) + the network's Gateway API. */
export interface GatewayNetwork {
  wallet: Address;
  minter: Address;
  api: string;
}

/** Portage deployment (Core + periphery) on the network's Arc chain. */
export interface PortageDeployment {
  appRegistry: Address;
  ledger: Address;
  payoutEngine: Address;
  router: Address;
  mintForwarder: Address;
}

/**
 * Conditional-settlement layer deployment. Each address is `PENDING` until the layer is deployed
 * to the network (SPEC §10.11); the same sentinel the `arcMainnet` network uses, so consumers get
 * a clear error instead of a wrong address. Resolve via {conditionAddress}, or pass an explicit
 * address to the wrapper.
 */
export interface ConditionsDeployment {
  conditionRegistry: Address | Pending;
  conditionalEscrow: Address | Pending;
  mutualReleaseCondition: Address | Pending;
  timelockCondition: Address | Pending;
  attestationCondition: Address | Pending;
  verdictCondition: Address | Pending;
}

/**
 * Coliseum Arena deployment — the dispute engine behind `VerdictCondition` (SPEC §7). Read by the
 * arena frontend (apps/arena) so it shares one source of truth with the SDK instead of hardcoding.
 */
export interface ArenaDeployment {
  arenaFactory: Address;
  reputationNft: Address;
}

/** A consolidation source chain: its Gateway domain and local USDC token. */
export interface SourceChainInfo {
  domain: number;
  usdc: Address;
}

export interface NetworkConfig {
  name: NetworkName;
  arc: ArcNetwork;
  gateway: GatewayNetwork;
  contracts: PortageDeployment;
  /** Conditional-settlement layer addresses (PENDING until deployed — SPEC §10.11). */
  conditions: ConditionsDeployment;
  /** Coliseum Arena deployment behind VerdictCondition (SPEC §7). */
  arena: ArenaDeployment;
  sourceChains: Record<SourceChain, SourceChainInfo>;
}

// ---------------------------------------------------------------------------
// Arc Testnet — the only fully-published network today.
// ---------------------------------------------------------------------------

/** Supported source chains for consolidation (CCTP/Gateway domains + local USDC). */
const ARC_TESTNET_SOURCE_CHAINS = {
  arcTestnet: { domain: 26, usdc: "0x3600000000000000000000000000000000000000" as Address },
  baseSepolia: { domain: 6, usdc: "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as Address },
  ethereumSepolia: { domain: 0, usdc: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as Address },
  arbitrumSepolia: { domain: 3, usdc: "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d" as Address },
  avalancheFuji: { domain: 1, usdc: "0x5425890298aed601595a70ab815c96711a31bc65" as Address },
} as const;

/** The consolidation source chains known to the SDK (keys are stable across networks). */
export type SourceChain = keyof typeof ARC_TESTNET_SOURCE_CHAINS;

export const ARC_TESTNET: NetworkConfig = {
  name: "arcTestnet",
  arc: {
    chainId: 5042002,
    domain: 26,
    usdc: "0x3600000000000000000000000000000000000000",
    explorerTx: "https://testnet.arcscan.app/tx/",
    explorerAddress: "https://testnet.arcscan.app/address/",
  },
  gateway: {
    wallet: "0x0077777d7EBA4688BDeF3E311b846F25870A19B9",
    minter: "0x0022222ABE238Cc2C7Bb1f21003F0a260052475B",
    api: "https://gateway-api-testnet.circle.com",
  },
  // Portage v0.1 contracts, deployed + wired on Arc Testnet (2026-07-20).
  // MintForwarder redeployed 2026-07-21 with the B1 change (executeMintWithMeta/hashMetaBinding).
  contracts: {
    appRegistry: "0xb803bF100F5CEb71dcC6Db20f8586A7A0901BB67",
    ledger: "0xEEc603760483B0689B76fb3780eE7edc2E1661b4",
    payoutEngine: "0xA9Ebe9fC146F6Bdb2FF5A688017eb496C56F66e0",
    router: "0x9eacb164e5B9D3D24b1A87437668B2245169eD4B",
    mintForwarder: "0x65473aF9a6006C20C100F6dBA174657b8D88aaed",
  },
  // Conditional-settlement layer, deployed + wired on Arc Testnet via DeployConditions.s.sol
  // (chain 5042002, deploy commit b734483; all 11 txs succeeded — 6 deploys + registerApp +
  // 4x setApproved). The escrow is registered as payoutController for appId
  // keccak256("portage-escrow-v1") and all four conditions are approved in the registry.
  conditions: {
    conditionRegistry: "0x82Df51DE89d7BD1068E60BBf7F27942D28021b29",
    conditionalEscrow: "0x2506618A73396aF31cdF3f1f407942fC6e52eDb5",
    mutualReleaseCondition: "0x92cEbd6Da8A8E3DD4aCBEfe24F43099Bd344Cd0b",
    timelockCondition: "0x168442bF6EA2d97A9290a696a22bf4c3E0667eEB",
    attestationCondition: "0x3E7b1D97050c2e59f87A4444f53e03dB8aa558af",
    verdictCondition: "0x479eCdF55EBe4F3868f1Ee0A0511c01B2CA4Bdec",
  },
  // Coliseum Arena on Arc Testnet — the canonical deployment (matches the Coliseum README and the
  // source absorbed into contracts/arena/). VerdictCondition resolves against ArenaFactory-created
  // arenas; the arena frontend reads these from here rather than hardcoding.
  arena: {
    arenaFactory: "0x13a38e7C2bA5AFA76a1AC21Eaef9f4DEA293FEBe",
    reputationNft: "0x953f508CdC9DC4FaA17D898a5e65A91a262F6607",
  },
  sourceChains: ARC_TESTNET_SOURCE_CHAINS,
};

// ---------------------------------------------------------------------------
// The network registry + selector.
// ---------------------------------------------------------------------------

/**
 * All networks. `arcMainnet` is intentionally PENDING: Circle has not published Arc mainnet's
 * chainId, Gateway domain, RPC, explorer, or native USDC address. Do NOT guess these — fill the
 * entry in once the values are official, then flip it from PENDING to a `NetworkConfig`.
 */
export const NETWORKS = {
  arcTestnet: ARC_TESTNET,
  arcMainnet: PENDING,
} as const satisfies Record<NetworkName, NetworkConfig | Pending>;

/** Resolve a network's config. Throws for networks whose values are not yet published. */
export function getNetwork(name: NetworkName = DEFAULT_NETWORK): NetworkConfig {
  const net = NETWORKS[name];
  if (net === PENDING) {
    throw new Error(
      `Portage network "${name}" is not available yet — Circle has not published Arc mainnet's ` +
        `chainId, Gateway domain, RPC, explorer, or native USDC address. ` +
        `Populate NETWORKS.${name} in config.ts once they are official.`,
    );
  }
  return net;
}

/** Whether a network's values are published (i.e. {getNetwork} will succeed). */
export function isNetworkAvailable(name: NetworkName): boolean {
  return NETWORKS[name] !== PENDING;
}

/** Name of a conditional-settlement contract in {ConditionsDeployment}. */
export type ConditionContract = keyof ConditionsDeployment;

/**
 * Resolve a conditional-settlement contract address. Throws while the layer is undeployed
 * (PENDING) on the network — pass an explicit address to the wrapper until §10.11 lands.
 */
export function conditionAddress(name: ConditionContract, network: NetworkConfig = getNetwork()): Address {
  const addr = network.conditions[name];
  if (addr === PENDING) {
    throw new Error(
      `Portage conditional-settlement contract "${name}" is not deployed on "${network.name}" yet ` +
        `(SPEC §10.11). Populate NETWORKS.${network.name}.conditions.${name} in config.ts once the ` +
        `deploy is verified, or pass an explicit address to the wrapper.`,
    );
  }
  return addr;
}

/** Whether a network's conditional-settlement layer is deployed (i.e. {conditionAddress} succeeds). */
export function isConditionsDeployed(network: NetworkConfig = getNetwork()): boolean {
  return Object.values(network.conditions).every((a) => a !== PENDING);
}

export function sourceChainDomain(chain: SourceChain, network: NetworkConfig = getNetwork()): number {
  return network.sourceChains[chain].domain;
}

export function sourceChainUsdc(chain: SourceChain, network: NetworkConfig = getNetwork()): Address {
  return network.sourceChains[chain].usdc;
}

// ---------------------------------------------------------------------------
// Deprecated flat exports — Arc Testnet only, kept for 0.1.x compatibility.
// Prefer getNetwork() and the returned NetworkConfig.
// ---------------------------------------------------------------------------

/** @deprecated Use `getNetwork().arc`. Arc Testnet only. */
export const ARC = {
  chainId: ARC_TESTNET.arc.chainId,
  domain: ARC_TESTNET.arc.domain,
  usdc: ARC_TESTNET.arc.usdc,
  explorer: "https://testnet.arcscan.app",
} as const;

/** @deprecated Use `getNetwork().gateway`. `apiTestnet` is now `gateway.api`. */
export const GATEWAY = {
  wallet: ARC_TESTNET.gateway.wallet,
  minter: ARC_TESTNET.gateway.minter,
  apiTestnet: ARC_TESTNET.gateway.api,
} as const;

/** @deprecated Use `getNetwork().contracts`. Arc Testnet v0.1 deployment. */
export const PORTAGE_ARC_TESTNET = ARC_TESTNET.contracts;

/** @deprecated Use `getNetwork().sourceChains`. Arc Testnet source chains. */
export const SOURCE_CHAINS = ARC_TESTNET.sourceChains;
