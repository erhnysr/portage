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
  appName,
  formatUsdc,
  quarantineReasonLabel,
  short,
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
  // ARC_RPC_URL (a dedicated key) overrides; otherwise fall back to the keyless default
  // (rpc.testnet.arc.network) so the manifest still renders without any env config.
  const rpcUrl = process.env.ARC_RPC_URL || DEFAULT_ARC_RPC_URL;
  // No `chain` needed for reads; transport carries the endpoint (with its key, if any).
  return createPublicClient({ transport: http(rpcUrl) });
}

type PublicClient = ReturnType<typeof client>;
type RouterLog = Log<bigint, number, false, undefined, true, [typeof CreditedEvent, typeof QuarantinedEvent]>;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// The keyless Arc endpoint rate-limits under load (code -32005 / "Request exceeds defined
// limit"). Treat those as transient and back off; surface any other error immediately.
function isRateLimit(err: unknown): boolean {
  const msg = String((err as { shortMessage?: string; message?: string })?.shortMessage ?? (err as Error)?.message ?? err);
  return /rate limit|exceeds defined limit|-32005|too many|429/i.test(msg);
}

function idOf(log: { transactionHash: `0x${string}` | null; logIndex: number | null }): string {
  return `${log.transactionHash}:${log.logIndex}`;
}

function toShipment(log: RouterLog): Shipment | null {
  // Combined getLogs (both events) tags each hit with `eventName`; branch on it.
  if (log.eventName === "Credited") {
    const args = log.args;
    const action = Number(args.action ?? 0);
    // Cargo carries the amount plus the deposit's purpose (PayoutAction), so the action stays
    // visible without pretending to be a consignee.
    const cargo =
      args.amount != null ? `${formatUsdc(args.amount)} USDC · ${actionLabel(action)}` : actionLabel(action);
    // Consignee is who the deposit was credited to: the app (name-resolved where known) and
    // its sub-account.
    const consignee =
      args.appId != null && args.account != null
        ? `${appName(args.appId)} / ${short(args.account)}`
        : "—";
    return {
      id: idOf(log),
      status: "cleared",
      txHash: log.transactionHash!,
      route: "Gateway → Arc",
      cargo,
      consignee,
      blockNumber: (log.blockNumber ?? 0n).toString(),
    };
  }
  if (log.eventName === "Quarantined") {
    const args = log.args;
    const reason = Number(args.reason ?? 0);
    return {
      id: idOf(log),
      status: "held",
      txHash: log.transactionHash!,
      route: "Held → Quarantine",
      cargo: args.amount != null ? `${formatUsdc(args.amount)} USDC` : "—",
      consignee: quarantineReasonLabel(reason),
      blockNumber: (log.blockNumber ?? 0n).toString(),
    };
  }
  return null;
}

// One combined getLogs (Credited OR Quarantined) for a <=10k-block window, with backoff on
// rate-limit. Throws (after retries) so the caller can count the window as failed.
async function fetchWindow(
  publicClient: PublicClient,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<Shipment[]> {
  const tries = 4;
  for (let attempt = 0; attempt < tries; attempt++) {
    try {
      const logs = (await publicClient.getLogs({
        address: ROUTER_ADDRESS,
        events: [CreditedEvent, QuarantinedEvent],
        fromBlock,
        toBlock,
      })) as RouterLog[];
      const out: Shipment[] = [];
      for (const l of logs) {
        const s = toShipment(l);
        if (s) out.push(s);
      }
      return out;
    } catch (err) {
      if (attempt < tries - 1 && isRateLimit(err)) {
        await sleep(600 * (attempt + 1)); // linear backoff: 0.6s, 1.2s, 1.8s
        continue;
      }
      throw err;
    }
  }
  return []; // unreachable (loop either returns or throws)
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
 * Two-anchor scan of the Router's Credited + Quarantined events. Scans a bounded band just
 * after deploy (historical proof) and a bounded band at the tip (recent activity), skipping
 * the empty middle. Overlapping windows are deduped by txHash:logIndex.
 *
 * Runs SEQUENTIALLY (one combined getLogs per window) with backoff, because the keyless Arc
 * endpoint rate-limits under parallel/rapid load. Windows are read defensively: a window that
 * still fails after retries is counted, not fatal. We only report { ok: false } when the scan
 * found nothing AND at least one window failed — i.e. we never claim "no shipments" off a
 * degraded read, and never invent rows.
 */
export async function getShipments(): Promise<ShipmentsResult> {
  try {
    const publicClient = client();
    const head = await publicClient.getBlockNumber();
    if (head < ROUTER_DEPLOY_BLOCK) return { ok: true, shipments: [] };

    // Merge both anchors' windows; a Map keyed by range string drops any exact overlap so we
    // never issue the same getLogs twice when the two bands meet on a short chain.
    const windowKey = (r: [bigint, bigint]) => `${r[0]}-${r[1]}`;
    const windows = new Map<string, [bigint, bigint]>();
    for (const r of floorRanges(head)) windows.set(windowKey(r), r);
    for (const r of tipRanges(head)) windows.set(windowKey(r), r);

    const byId = new Map<string, Shipment>();
    let failures = 0;
    let first = true;
    for (const [from, to] of windows.values()) {
      if (!first) await sleep(120); // gentle spacing between windows
      first = false;
      try {
        const rows = await fetchWindow(publicClient, from, to);
        for (const row of rows) byId.set(row.id, row); // dedupe across overlapping bands
      } catch {
        failures++; // tolerate a degraded window; don't blank the whole table for one miss
      }
    }

    // Honest empties: only surface "no shipments" when we actually read cleanly. If we found
    // nothing but some windows failed, the read was degraded → report unavailable instead.
    if (byId.size === 0 && failures > 0) return { ok: false };

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
