// On-chain facts and tuning knobs for the live "Cleared shipments" manifest.
// Pure constants — safe to import from client or server (no secrets here).

import { parseAbiItem } from "viem";

// --- Network-keyed config ---------------------------------------------------
// Every chain-specific fact lives in one PortageNetwork, selected by NETWORK_NAME
// (PORTAGE_NETWORK / NEXT_PUBLIC_PORTAGE_NETWORK env, default arcTestnet). Arc mainnet
// is PENDING until Circle publishes its chainId / RPC / explorer / Router deployment —
// do NOT guess those values; fill ARC_MAINNET in once they are official.

export type NetworkName = "arcTestnet" | "arcMainnet";

/** Sentinel for a network whose values Circle has not published yet. */
export const PENDING = null;
export type Pending = typeof PENDING;

export interface PortageNetwork {
  chainId: number;
  /** Blockscout explorer base for transactions, e.g. `${explorerTx}<hash>`. */
  explorerTx: string;
  /** Blockscout explorer base for addresses, e.g. `${explorerAddress}<addr>`. */
  explorerAddress: string;
  /** Fallback Arc RPC when ARC_RPC_URL is not set. */
  defaultRpcUrl: string;
  /** PortageRouter address on this network. */
  router: `0x${string}`;
  /** Block the Router was deployed at — the floor for its event history. */
  routerDeployBlock: bigint;
}

const ARC_TESTNET: PortageNetwork = {
  chainId: 5042002,
  explorerTx: "https://testnet.arcscan.app/tx/",
  explorerAddress: "https://testnet.arcscan.app/address/",
  // Default Arc testnet RPC when ARC_RPC_URL is not set. Set a dedicated key via env to
  // override (recommended for prod). Public keyless endpoints were benchmarked against the
  // full two-anchor workload (~90 getLogs, needs archive history back to the deploy era):
  //   - drpc      → the ONLY keyless endpoint that completes it (~8-13s). Chosen default.
  //   - arc.io    → full history, but caps request RATE; fails after ~2 windows keyless.
  //   - quicknode → full history, but caps request RATE; fails after ~1 window keyless.
  //   - blockdaemon → DISQUALIFIED: pruned node, returns code 4444 "pruned history
  //     unavailable" for deploy-era blocks. It cannot serve the floor anchor at all — do
  //     not use it here regardless of rate limits.
  defaultRpcUrl: "https://rpc.drpc.testnet.arc.io",
  // PortageRouter on Arc testnet. NOT redeployed since the original Deploy.s.sol run,
  // so its deploy block below is the correct floor for its event history.
  router: "0x9eacb164e5B9D3D24b1A87437668B2245169eD4B",
  // Floor for Credited / Quarantined logs: the Router emits nothing before it exists.
  // From the broadcast receipt of Router deploy tx 0xbd406aa3… (Arc testnet, chainId 5042002).
  // This is an immutable historical fact, hence a hardcoded constant rather than config/env.
  routerDeployBlock: 52667877n,
};

// Arc mainnet not yet published by Circle — chainId / RPC / explorer / Router all TBD.
export const NETWORKS: Record<NetworkName, PortageNetwork | Pending> = {
  arcTestnet: ARC_TESTNET,
  arcMainnet: PENDING,
};

function selectedNetworkName(): NetworkName {
  const raw = process.env.NEXT_PUBLIC_PORTAGE_NETWORK ?? process.env.PORTAGE_NETWORK;
  return raw === "arcMainnet" ? "arcMainnet" : "arcTestnet";
}

export const NETWORK_NAME: NetworkName = selectedNetworkName();

/** Resolve a network's config. Throws for networks whose values are not yet published. */
export function getNetwork(name: NetworkName = NETWORK_NAME): PortageNetwork {
  const net = NETWORKS[name];
  if (net === PENDING) {
    throw new Error(
      `Portage network "${name}" is not available yet — Circle has not published Arc mainnet's ` +
        `chainId, RPC, explorer, or Router deployment. Populate NETWORKS.${name} in lib/portage.ts once official.`,
    );
  }
  return net;
}

/** The active network for this deployment. */
export const NETWORK = getNetwork();

// Backward-compatible named exports, sourced from the active network.
export const ARC_CHAIN_ID = NETWORK.chainId;
export const ARC_EXPLORER_TX = NETWORK.explorerTx;
export const ARC_EXPLORER_ADDRESS = NETWORK.explorerAddress;
export const DEFAULT_ARC_RPC_URL = NETWORK.defaultRpcUrl;
export const ROUTER_ADDRESS = NETWORK.router;
export const ROUTER_DEPLOY_BLOCK = NETWORK.routerDeployBlock;

// eth_getLogs window: Arc RPC rejects ranges wider than ~10k blocks, so we page.
export const LOG_WINDOW = 10000n;

// Two-anchor scan. On a tall, fast-growing testnet the historical proof events cluster
// just after deploy while any new activity lands near the tip; the huge empty middle is
// skipped. Both anchors are bounded so per-revalidation cost stays flat as the chain grows.
//
// Floor anchor: scan FORWARD from the Router deploy block. The demo Credited event sits at
// deploy +~234k blocks, so this must cover >=24 windows to reach it; 30 leaves margin.
export const FLOOR_WINDOWS = 30;
// Tip anchor: scan BACKWARD from head to catch recent consolidations. ~150k blocks of look-back.
export const TIP_WINDOWS = 15;

// Max rows the manifest table renders.
export const MAX_ROWS = 12;

// Router events that make up the manifest.
export const CreditedEvent = parseAbiItem(
  "event Credited(bytes32 indexed appId, bytes32 indexed account, uint256 amount, bytes32 indexed specHash, uint8 action, bytes32 referenceId)",
);
export const QuarantinedEvent = parseAbiItem(
  "event Quarantined(bytes32 indexed specHash, uint256 amount, uint8 reason)",
);

// PayoutAction enum (PayoutMetaLib) → display label.
export const ACTION_LABELS = ["Credit", "Entry fee", "Escrow fund", "Top-up"] as const;

// QuarantineReason enum (PortageRouter) → display label.
export const QUARANTINE_REASON_LABELS = ["Malformed hookData", "Unregistered app"] as const;

export function actionLabel(action: number): string {
  return ACTION_LABELS[action] ?? `Action #${action}`;
}

export function quarantineReasonLabel(reason: number): string {
  return QUARANTINE_REASON_LABELS[reason] ?? `Reason #${reason}`;
}

// Known appId (keccak256 of the app name) → display name. appId is opaque on-chain, so we
// reverse-map the ones we know; anything else falls back to a short hash.
export const APP_NAMES: Record<string, string> = {
  "0xee1b38d84672bb4ae7bf6e6e779a54a05e94092183ce62aa3f5329094652e2b6": "coliseum",
};

export function appName(appId: string): string {
  return APP_NAMES[appId.toLowerCase()] ?? short(appId);
}

// USDC is 6-decimal. Format an atomic amount as a short human string, e.g. "5.00".
export function formatUsdc(atomic: bigint): string {
  const whole = atomic / 1_000_000n;
  const frac = (atomic % 1_000_000n).toString().padStart(6, "0").slice(0, 2);
  return `${whole.toString()}.${frac}`;
}

// Short 0x… form for a hash/address (8 hex chars after the prefix).
export function short(hex: string): string {
  return `${hex.slice(0, 10)}`;
}
