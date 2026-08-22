// On-chain facts and tuning knobs for the live "Cleared shipments" manifest.
// Pure constants — safe to import from client or server (no secrets here).

import { parseAbiItem } from "viem";

export const ARC_CHAIN_ID = 5042002;
export const ARC_EXPLORER_TX = "https://testnet.arcscan.app/tx/";
export const ARC_EXPLORER_ADDRESS = "https://testnet.arcscan.app/address/";

// PortageRouter on Arc testnet. NOT redeployed since the original Deploy.s.sol run,
// so its deploy block below is the correct floor for its event history.
export const ROUTER_ADDRESS = "0x9eacb164e5B9D3D24b1A87437668B2245169eD4B" as const;

// Floor for Credited / Quarantined logs: the Router emits nothing before it exists.
// From the broadcast receipt of Router deploy tx 0xbd406aa3… (Arc testnet, chainId 5042002).
// This is an immutable historical fact, hence a hardcoded constant rather than config/env.
export const ROUTER_DEPLOY_BLOCK = 52667877n;

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
