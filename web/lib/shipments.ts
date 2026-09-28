import "server-only";

import { createPublicClient, decodeEventLog, http, type Hex, type Log } from "viem";
import {
  ARC_EXPLORER_API,
  CreditedEvent,
  QuarantinedEvent,
  DEFAULT_ARC_RPC_URL,
  FLOOR_WINDOWS,
  LOG_WINDOW,
  ROUTER_ADDRESS,
  ROUTER_DEPLOY_BLOCK,
  TIP_WINDOWS,
  actionLabel,
  appName,
  formatUsdc,
  quarantineReasonLabel,
  short,
} from "./portage";

// A single manifest entry, already shaped for rendering (no bigints leak to the client).
export type Shipment = {
  id: string; // txHash:logIndex — stable React key + dedupe key across sources/windows
  status: "cleared" | "held";
  txHash: `0x${string}`;
  route: string;
  cargo: string; // formatted USDC (+ action), or "—"
  consignee: string;
  blockNumber: string; // stringified for serialization; parsed back to bigint only for sort
  /** ISO block time when the source provides it (indexer), else null (RPC scan). */
  timestamp: string | null;
  /** Atomic USDC amount (6 decimals) as a decimal string. */
  amount: string;
  appId: string | null;
  account: string | null;
  action: number | null;
  specHash: string | null;
  referenceId: string | null;
  /** QuarantineReason for held shipments. */
  reason: number | null;
};

// Discriminated result so the component can branch on ok/empty/error explicitly and
// never has to invent placeholder rows. `source` says where the rows were read from.
export type ShipmentsResult =
  | { ok: true; shipments: Shipment[]; source: "indexer" | "rpc" }
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
      timestamp: null,
      amount: (args.amount ?? 0n).toString(),
      appId: args.appId ?? null,
      account: args.account ?? null,
      action,
      specHash: args.specHash ?? null,
      referenceId: args.referenceId ?? null,
      reason: null,
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
      timestamp: null,
      amount: (args.amount ?? 0n).toString(),
      appId: null,
      account: null,
      action: null,
      specHash: args.specHash ?? null,
      referenceId: null,
      reason,
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
async function scanRpc(): Promise<ShipmentsResult> {
  try {
    const publicClient = client();
    const head = await publicClient.getBlockNumber();
    if (head < ROUTER_DEPLOY_BLOCK) return { ok: true, shipments: [], source: "rpc" };

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

    return { ok: true, shipments: sortNewestFirst([...byId.values()]), source: "rpc" };
  } catch {
    return { ok: false };
  }
}

function sortNewestFirst(rows: Shipment[]): Shipment[] {
  return rows.sort((a, b) => {
    const d = BigInt(b.blockNumber) - BigInt(a.blockNumber);
    return d > 0n ? 1 : d < 0n ? -1 : 0;
  });
}

// ---------------------------------------------------------------------------------------
// Indexer path (primary). Arc's Blockscout explorer indexes every Router log, so one paged
// REST call returns the Router's FULL history — unlike the bounded RPC scan above, which
// only sees a band after deploy and ~150k blocks (~21h on Arc testnet) back from the tip.
// We do NOT trust Blockscout's own decoding: each log's raw topics/data are decoded here
// against the Router's event ABI, exactly as the RPC path does.
// ---------------------------------------------------------------------------------------

type BlockscoutLog = {
  topics: (string | null)[];
  data: string;
  index: number;
  block_number: number;
  block_timestamp: string | null;
  transaction_hash: `0x${string}`;
};
type BlockscoutPage = { items: BlockscoutLog[]; next_page_params: Record<string, string | number> | null };

const INDEXER_MAX_PAGES = 20; // 50 logs/page → ample for a testnet Router; bounded either way

function fromIndexerLog(item: BlockscoutLog): Shipment | null {
  const topics = item.topics.filter((t): t is string => typeof t === "string") as [Hex, ...Hex[]];
  if (topics.length === 0) return null;
  let decoded;
  try {
    decoded = decodeEventLog({
      abi: [CreditedEvent, QuarantinedEvent],
      topics,
      data: item.data as Hex,
    });
  } catch {
    return null; // not a manifest event (ownership, forwarder updates, …)
  }
  const shaped = toShipment({
    ...decoded,
    transactionHash: item.transaction_hash,
    logIndex: item.index,
    blockNumber: BigInt(item.block_number),
  } as unknown as RouterLog);
  if (!shaped) return null;
  return { ...shaped, timestamp: item.block_timestamp ?? null };
}

async function readIndexer(): Promise<ShipmentsResult> {
  const base = `${ARC_EXPLORER_API}/addresses/${ROUTER_ADDRESS}/logs`;
  const rows: Shipment[] = [];
  let query = "";
  for (let page = 0; page < INDEXER_MAX_PAGES; page++) {
    const res = await fetch(base + query, {
      headers: { accept: "application/json" },
      next: { revalidate: 60 },
    });
    if (!res.ok) throw new Error(`indexer ${res.status}`);
    const body = (await res.json()) as BlockscoutPage;
    if (!Array.isArray(body.items)) throw new Error("indexer: unexpected shape");
    for (const item of body.items) {
      const s = fromIndexerLog(item);
      if (s) rows.push(s);
    }
    if (!body.next_page_params) break;
    query = "?" + new URLSearchParams(
      Object.entries(body.next_page_params).map(([k, v]) => [k, String(v)]),
    ).toString();
  }
  return { ok: true, shipments: sortNewestFirst(rows), source: "indexer" };
}

/**
 * All Router shipments, newest first. Reads the indexer (full history, with block times);
 * if that fails, falls back to the bounded direct-RPC scan. `limit` trims the result.
 */
export async function getShipments(opts: { limit?: number } = {}): Promise<ShipmentsResult> {
  let result: ShipmentsResult;
  try {
    result = await readIndexer();
  } catch {
    result = await scanRpc();
  }
  if (result.ok && opts.limit != null) {
    return { ...result, shipments: result.shipments.slice(0, opts.limit) };
  }
  return result;
}

