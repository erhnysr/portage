import "server-only";

import { createPublicClient, http, type Log } from "viem";
import {
  CreditedEvent,
  QuarantinedEvent,
  DEFAULT_ARC_RPC_URL,
  FLOOR_WINDOWS,
  LOG_WINDOW,
  MAX_ROWS,
  ROUTER_ADDRESS,
  ROUTER_DEPLOY_BLOCK,
  TIP_WINDOWS,
  actionLabel,
  formatUsdc,
  quarantineReasonLabel,
} from "./portage";

// A single manifest entry, already shaped for the table (no bigints leak to the client).
export type Shipment = {
  id: string; // txHash:logIndex — stable React key + dedupe key across overlapping windows
  status: "cleared" | "held";
  txHash: `0x${string}`;
  route: string;
  cargo: string; // formatted USDC, or "—"
  consignee: string;
  blockNumber: string; // stringified for serialization; parsed back to bigint only for sort
};

// Discriminated result so the component can branch on ok/empty/error explicitly and
// never has to invent placeholder rows.
export type ShipmentsResult =
  | { ok: true; shipments: Shipment[] }
  | { ok: false };

function client() {
  // ARC_RPC_URL (a dedicated key) overrides; otherwise fall back to the benchmarked
  // keyless default so the manifest still renders without any env config.
  const rpcUrl = process.env.ARC_RPC_URL || DEFAULT_ARC_RPC_URL;
  // No `chain` needed for reads; transport carries the endpoint (with its key, if any).
  return createPublicClient({ transport: http(rpcUrl) });
}

type CreditedLog = Log<bigint, number, false, typeof CreditedEvent>;
type QuarantinedLog = Log<bigint, number, false, typeof QuarantinedEvent>;

function idOf(log: { transactionHash: `0x${string}` | null; logIndex: number | null }): string {
  return `${log.transactionHash}:${log.logIndex}`;
}

function toClearedShipment(log: CreditedLog): Shipment {
  const action = Number(log.args.action ?? 0);
  return {
    id: idOf(log),
    status: "cleared",
    txHash: log.transactionHash!,
    route: "GATEWAY → ARC",
    cargo: log.args.amount != null ? `${formatUsdc(log.args.amount)} USDC` : "—",
    consignee: actionLabel(action),
    blockNumber: (log.blockNumber ?? 0n).toString(),
  };
}

function toHeldShipment(log: QuarantinedLog): Shipment {
  const reason = Number(log.args.reason ?? 0);
  return {
    id: idOf(log),
    status: "held",
    txHash: log.transactionHash!,
    route: "HELD → QUARANTINE",
    cargo: log.args.amount != null ? `${formatUsdc(log.args.amount)} USDC` : "—",
    consignee: quarantineReasonLabel(reason),
    blockNumber: (log.blockNumber ?? 0n).toString(),
  };
}

type PublicClient = ReturnType<typeof client>;

// Fetch both Router events for one <=10k-block window, in parallel. Concurrency here is
// fine on the default endpoint (drpc): measured against the full ~90-call workload it
// completes in ~8-13s. Dropping to sequential was tested and gained nothing — the stricter
// keyless endpoints (arc.io, quicknode) cap total request RATE, not just concurrency, so
// they fail after 1-2 windows either way; sequential only doubled drpc's latency.
async function fetchWindow(
  publicClient: PublicClient,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<Shipment[]> {
  const [credited, quarantined] = await Promise.all([
    publicClient.getLogs({ address: ROUTER_ADDRESS, event: CreditedEvent, fromBlock, toBlock }),
    publicClient.getLogs({ address: ROUTER_ADDRESS, event: QuarantinedEvent, fromBlock, toBlock }),
  ]);
  return [
    ...credited.map((l) => toClearedShipment(l as CreditedLog)),
    ...quarantined.map((l) => toHeldShipment(l as QuarantinedLog)),
  ];
}

// Build the [from,to] windows for the floor anchor: forward from deploy, clamped to head.
function floorRanges(head: bigint): Array<[bigint, bigint]> {
  const ranges: Array<[bigint, bigint]> = [];
  let from = ROUTER_DEPLOY_BLOCK;
  for (let i = 0; i < FLOOR_WINDOWS && from <= head; i++) {
    const to = from + (LOG_WINDOW - 1n) > head ? head : from + (LOG_WINDOW - 1n);
    ranges.push([from, to]);
    if (to === head) break;
    from = to + 1n;
  }
  return ranges;
}

// Build the [from,to] windows for the tip anchor: backward from head, clamped to deploy.
function tipRanges(head: bigint): Array<[bigint, bigint]> {
  const ranges: Array<[bigint, bigint]> = [];
  let to = head;
  for (let i = 0; i < TIP_WINDOWS && to >= ROUTER_DEPLOY_BLOCK; i++) {
    const from = to - (LOG_WINDOW - 1n) < ROUTER_DEPLOY_BLOCK ? ROUTER_DEPLOY_BLOCK : to - (LOG_WINDOW - 1n);
    ranges.push([from, to]);
    if (from === ROUTER_DEPLOY_BLOCK) break;
    to = from - 1n;
  }
  return ranges;
}

/**
 * Two-anchor scan of the Router's Credited + Quarantined events. Scans a bounded band
 * just after deploy (historical proof) and a bounded band at the tip (recent activity),
 * skipping the empty middle. Overlapping windows are deduped by txHash:logIndex. Returns
 * { ok: false } on any RPC failure so the UI shows an honest error state, never fake rows.
 */
export async function getShipments(): Promise<ShipmentsResult> {
  try {
    const publicClient = client();
    const head = await publicClient.getBlockNumber();
    if (head < ROUTER_DEPLOY_BLOCK) return { ok: true, shipments: [] };

    // Merge both anchors' windows; a Map keyed by range string drops any exact overlap so
    // we never issue the same getLogs twice when the two bands meet on a short chain.
    const windowKey = (r: [bigint, bigint]) => `${r[0]}-${r[1]}`;
    const windows = new Map<string, [bigint, bigint]>();
    for (const r of floorRanges(head)) windows.set(windowKey(r), r);
    for (const r of tipRanges(head)) windows.set(windowKey(r), r);

    const byId = new Map<string, Shipment>();
    for (const [from, to] of windows.values()) {
      const rows = await fetchWindow(publicClient, from, to);
      for (const row of rows) byId.set(row.id, row); // dedupe events across overlapping bands
    }

    const shipments = [...byId.values()]
      .sort((a, b) => {
        const d = BigInt(b.blockNumber) - BigInt(a.blockNumber);
        return d > 0n ? 1 : d < 0n ? -1 : 0;
      })
      .slice(0, MAX_ROWS);

    return { ok: true, shipments };
  } catch {
    return { ok: false };
  }
}
