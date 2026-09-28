import "server-only";

import { unstable_cache } from "next/cache";

import {
  decodeEventLog,
  decodeFunctionData,
  getAddress,
  hexToBigInt,
  hexToNumber,
  isAddressEqual,
  keccak256,
  parseAbi,
  recoverTypedDataAddress,
  slice,
  type Hex,
} from "viem";
import {
  ARC_CHAIN_ID,
  ARC_EXPLORER_API,
  CreditedEvent,
  QuarantinedEvent,
  ROUTER_ADDRESS,
  bytes32ToAddress,
} from "./portage";

// PortageMintForwarder (B1, executeMintWithMeta) on Arc testnet — the EIP-712 verifying
// contract for the PayoutMeta binding. See CLAUDE.md "Deployed addresses".
export const FORWARDER_ADDRESS = "0x65473aF9a6006C20C100F6dBA174657b8D88aaed" as const;

const forwarderAbi = parseAbi([
  "function executeMintWithMeta(bytes attestationPayload, bytes signature, (uint8 schema, bytes32 appId, bytes32 account, uint8 action, bytes32 referenceId, bytes32 payer) meta, bytes metaSig)",
  "function executeMint(bytes attestationPayload, bytes signature)",
]);

// Mirrors sdk/src/client.ts META_BINDING_TYPES — what the depositor signed.
const META_BINDING_TYPES = {
  PayoutMetaBinding: [
    { name: "specHash", type: "bytes32" },
    { name: "schema", type: "uint8" },
    { name: "appId", type: "bytes32" },
    { name: "account", type: "bytes32" },
    { name: "action", type: "uint8" },
    { name: "referenceId", type: "bytes32" },
    { name: "payer", type: "bytes32" },
  ],
} as const;

const ATTESTATION_MAGIC = "0xff6fb334";

/** Fields read from a Circle Gateway single-Attestation payload. Offsets match
 *  contracts/lib/AttestationDecoder.sol (envelope: magic 4 | maxBlockHeight 32 | specLen 4 | spec). */
export type DecodedAttestation = {
  magicOk: boolean;
  maxBlockHeight: string;
  sourceDomain: number;
  destinationDomain: number;
  sourceContract: `0x${string}`;
  destinationContract: `0x${string}`;
  sourceToken: `0x${string}`;
  destinationToken: `0x${string}`;
  sourceDepositor: `0x${string}`;
  destinationRecipient: `0x${string}`;
  destinationCaller: `0x${string}`;
  value: string; // atomic USDC
  hookDataLength: number;
  specHash: Hex; // keccak256(encoded TransferSpec) — recomputed here
};

export function decodeAttestation(payload: Hex): DecodedAttestation {
  const at = (start: number, len: number) => slice(payload, start, start + len);
  const addr = (start: number) => getAddress(bytes32ToAddress(at(start, 32)));
  const specLen = hexToNumber(at(36, 4));
  // TransferSpec (spec-relative): magic 0 | version 4 | srcDomain 8 | dstDomain 12 |
  // srcContract 16 | dstContract 48 | srcToken 80 | dstToken 112 | depositor 144 |
  // recipient 176 | signer 208 | caller 240 | value 272 | salt 304 | hookLen 336 | hook 340
  const S = 40;
  return {
    magicOk: at(0, 4).toLowerCase() === ATTESTATION_MAGIC,
    maxBlockHeight: hexToBigInt(at(4, 32)).toString(),
    sourceDomain: hexToNumber(at(S + 8, 4)),
    destinationDomain: hexToNumber(at(S + 12, 4)),
    sourceContract: addr(S + 16),
    destinationContract: addr(S + 48),
    sourceToken: addr(S + 80),
    destinationToken: addr(S + 112),
    sourceDepositor: addr(S + 144),
    destinationRecipient: addr(S + 176),
    destinationCaller: addr(S + 240),
    value: hexToBigInt(at(S + 272, 32)).toString(),
    hookDataLength: hexToNumber(at(S + 336, 4)),
    specHash: keccak256(at(S, specLen)),
  };
}

export type Check = { label: string; ok: boolean; detail: string };

export type ShipmentDetail = {
  txHash: `0x${string}`;
  status: "cleared" | "held";
  txSucceeded: boolean;
  blockNumber: string;
  timestamp: string | null;
  submitter: `0x${string}`;
  feeWei: string; // native gas on Arc is USDC with 18 decimals
  method: "executeMintWithMeta" | "executeMint";
  attestation: DecodedAttestation;
  credited: {
    amount: string;
    appId: string;
    account: string;
    action: number;
    specHash: string;
    referenceId: string;
  } | null;
  quarantined: { amount: string; reason: number; specHash: string } | null;
  meta: {
    schema: number;
    appId: string;
    account: string;
    action: number;
    referenceId: string;
    payer: string;
  } | null;
  metaSigner: `0x${string}` | null;
  checks: Check[];
};

export type DetailResult =
  | { ok: true; detail: ShipmentDetail }
  | { ok: false; reason: "not-found" | "not-portage" | "unavailable" };

type BlockscoutTx = {
  hash: `0x${string}`;
  status: string | null;
  result: string;
  block_number: number | null;
  timestamp: string | null;
  from: { hash: `0x${string}` } | null;
  to: { hash: `0x${string}` } | null;
  raw_input: Hex;
  fee: { value: string } | null;
};
type BlockscoutLogs = {
  items: { address: { hash: string }; topics: (string | null)[]; data: Hex }[];
};

class NotIndexed extends Error {}

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(`${ARC_EXPLORER_API}${path}`, {
    headers: { accept: "application/json" },
    cache: "no-store", // caching happens one level up, and only for successful reads
  });
  if (res.status === 404 || res.status === 422) throw new NotIndexed(path);
  if (!res.ok) throw new Error(`explorer ${res.status} for ${path}`);
  return (await res.json()) as T;
}

// A confirmed transaction never changes, so a successful read is cached for an hour. A miss
// (not yet indexed, bad hash, explorer hiccup) THROWS, and unstable_cache never stores a throw —
// so a shipment opened seconds after it lands is retried on the next request, not pinned as 404.
const loadTx = unstable_cache(
  async (txHash: string) => {
    const [tx, logs] = await Promise.all([
      getJson<BlockscoutTx>(`/transactions/${txHash}`),
      getJson<BlockscoutLogs>(`/transactions/${txHash}/logs`),
    ]);
    return { tx, logs };
  },
  ["portage-shipment-v1"],
  { revalidate: 3600 },
);

export async function getShipmentDetail(txHash: `0x${string}`): Promise<DetailResult> {
  let tx: BlockscoutTx;
  let logs: BlockscoutLogs;
  try {
    ({ tx, logs } = await loadTx(txHash.toLowerCase()));
  } catch (err) {
    return { ok: false, reason: err instanceof NotIndexed ? "not-found" : "unavailable" };
  }

  // Decode the calldata ourselves — we only trust bytes, not the indexer's interpretation.
  let call;
  try {
    call = decodeFunctionData({ abi: forwarderAbi, data: tx.raw_input });
  } catch {
    return { ok: false, reason: "not-portage" };
  }

  const payload = call.args[0] as Hex;
  let attestation: DecodedAttestation;
  try {
    attestation = decodeAttestation(payload);
  } catch {
    return { ok: false, reason: "not-portage" };
  }

  // Router events emitted in this transaction.
  let credited: ShipmentDetail["credited"] = null;
  let quarantined: ShipmentDetail["quarantined"] = null;
  for (const log of logs.items) {
    if (!isAddressEqual(log.address.hash as `0x${string}`, ROUTER_ADDRESS)) continue;
    const topics = log.topics.filter((t): t is string => typeof t === "string") as [Hex, ...Hex[]];
    try {
      const ev = decodeEventLog({ abi: [CreditedEvent, QuarantinedEvent], topics, data: log.data });
      if (ev.eventName === "Credited") {
        credited = {
          amount: ev.args.amount.toString(),
          appId: ev.args.appId,
          account: ev.args.account,
          action: Number(ev.args.action),
          specHash: ev.args.specHash,
          referenceId: ev.args.referenceId,
        };
      } else {
        quarantined = {
          amount: ev.args.amount.toString(),
          reason: Number(ev.args.reason),
          specHash: ev.args.specHash,
        };
      }
    } catch {
      /* other Router events are irrelevant here */
    }
  }
  if (!credited && !quarantined) return { ok: false, reason: "not-portage" };

  let meta: ShipmentDetail["meta"] = null;
  let metaSigner: `0x${string}` | null = null;
  if (call.functionName === "executeMintWithMeta") {
    const m = call.args[2] as {
      schema: number;
      appId: Hex;
      account: Hex;
      action: number;
      referenceId: Hex;
      payer: Hex;
    };
    meta = {
      schema: Number(m.schema),
      appId: m.appId,
      account: m.account,
      action: Number(m.action),
      referenceId: m.referenceId,
      payer: m.payer,
    };
    try {
      metaSigner = await recoverTypedDataAddress({
        domain: { name: "Portage", version: "1", chainId: ARC_CHAIN_ID, verifyingContract: FORWARDER_ADDRESS },
        types: META_BINDING_TYPES,
        primaryType: "PayoutMetaBinding",
        message: {
          specHash: attestation.specHash,
          schema: meta.schema,
          appId: m.appId,
          account: m.account,
          action: meta.action,
          referenceId: m.referenceId,
          payer: m.payer,
        },
        signature: call.args[3] as Hex,
      });
    } catch {
      metaSigner = null;
    }
  }

  const eventSpecHash = (credited?.specHash ?? quarantined?.specHash ?? "").toLowerCase();
  const eventAmount = credited?.amount ?? quarantined?.amount ?? "0";
  const checks: Check[] = [
    {
      label: "Circle Gateway attestation",
      ok: attestation.magicOk,
      detail: attestation.magicOk
        ? "Payload starts with the Gateway Attestation magic 0xff6fb334."
        : "Payload does not carry the Gateway Attestation magic.",
    },
    {
      label: "Transfer spec matches the ledger entry",
      ok: attestation.specHash.toLowerCase() === eventSpecHash,
      detail: "keccak256 of the attested TransferSpec, recomputed here, equals the specHash in the Router event.",
    },
    {
      label: "Minted to the Portage Router",
      ok: isAddressEqual(attestation.destinationRecipient, ROUTER_ADDRESS),
      detail: "The attestation's destinationRecipient is the Router, so the funds could only land in Portage custody.",
    },
    {
      label: "Credited amount equals attested value",
      ok: attestation.value === eventAmount,
      detail: "The amount recorded on Arc is exactly the value Circle attested — nothing skimmed, nothing added.",
    },
  ];
  if (meta) {
    checks.push({
      label: "Routing signed by the depositor",
      ok: metaSigner != null && isAddressEqual(metaSigner, attestation.sourceDepositor),
      detail:
        "The EIP-712 PayoutMeta signature, recovered here, belongs to the address that deposited on the source chain.",
    });
    checks.push({
      label: "Payer recorded is the depositor",
      ok: isAddressEqual(bytes32ToAddress(meta.payer), attestation.sourceDepositor),
      detail: "The audit-trail payer written with the credit is the same source-chain depositor.",
    });
  }

  return {
    ok: true,
    detail: {
      txHash: tx.hash,
      status: credited ? "cleared" : "held",
      txSucceeded: tx.status === "ok" || tx.result === "success",
      blockNumber: String(tx.block_number ?? ""),
      timestamp: tx.timestamp,
      submitter: getAddress(tx.from?.hash ?? "0x0000000000000000000000000000000000000000"),
      feeWei: tx.fee?.value ?? "0",
      method: call.functionName,
      attestation,
      credited,
      quarantined,
      meta,
      metaSigner,
      checks,
    },
  };
}
