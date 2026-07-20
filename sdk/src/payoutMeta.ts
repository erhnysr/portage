import { encodeAbiParameters, decodeAbiParameters, keccak256, pad, toHex, type Address, type Hex } from "viem";

/** Action semantics for a consolidation credit (matches PayoutAction in the contracts). */
export enum PayoutAction {
  Credit = 0,
  EntryFee = 1,
  EscrowFund = 2,
  Topup = 3,
}

export const PAYOUT_META_SCHEMA_V1 = 1;

/** Portage payout metadata carried inside the Gateway burn intent's hookData (ARCHITECTURE.md §4). */
export interface PayoutMeta {
  /** Version tag; defaults to 1 when encoding. */
  schema?: number;
  /** Which app's ledger to credit. */
  appId: Hex;
  /** Sub-account within the app (e.g. an arena id). */
  account: Hex;
  /** See PayoutAction. */
  action: PayoutAction;
  /** App-side id for reconciliation. */
  referenceId: Hex;
  /** Original depositor (audit trail). */
  payer: Hex;
}

const PAYOUT_META_ABI = [
  { type: "uint8" },
  { type: "bytes32" },
  { type: "bytes32" },
  { type: "uint8" },
  { type: "bytes32" },
  { type: "bytes32" },
] as const;

/** Encodes PayoutMeta to the exact bytes the on-chain PayoutMetaLib.tryDecode expects (192 bytes). */
export function encodePayoutMeta(meta: PayoutMeta): Hex {
  return encodeAbiParameters(PAYOUT_META_ABI, [
    meta.schema ?? PAYOUT_META_SCHEMA_V1,
    meta.appId,
    meta.account,
    meta.action,
    meta.referenceId,
    meta.payer,
  ]);
}

export function decodePayoutMeta(data: Hex): PayoutMeta {
  const [schema, appId, account, action, referenceId, payer] = decodeAbiParameters(PAYOUT_META_ABI, data);
  return { schema, appId, account, action: action as PayoutAction, referenceId, payer };
}

/** Left-pad an address to bytes32, lowercased (encoding hygiene — avoids mixed-case hex). */
export function addressToBytes32(addr: Address): Hex {
  return pad(addr.toLowerCase() as Hex, { size: 32 });
}

/** Ordered tuple [schema, appId, account, action, referenceId, payer] for contract calls. */
export function payoutMetaTuple(meta: PayoutMeta): [number, Hex, Hex, number, Hex, Hex] {
  return [meta.schema ?? PAYOUT_META_SCHEMA_V1, meta.appId, meta.account, meta.action, meta.referenceId, meta.payer];
}

/** Derive a bytes32 app id from a human name, e.g. appIdFromName("coliseum"). */
export function appIdFromName(name: string): Hex {
  return keccak256(toHex(name));
}

/** Derive a bytes32 account id from a human name, e.g. accountIdFromName("arena-1"). */
export function accountIdFromName(name: string): Hex {
  return keccak256(toHex(name));
}
