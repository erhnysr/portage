import { encodeAbiParameters, keccak256, type Address, type Hex } from "viem";

/**
 * Deal lifecycle state, mirroring `IConditionalEscrow.State` (the on-chain enum). Values match the
 * `uint8` returned by `stateOf` — use these instead of raw numbers when reading a deal's state.
 */
export enum DealState {
  None = 0,
  Funded = 1,
  Resolving = 2,
  Resolved = 3,
  Claimed = 4,
  Refunded = 5,
  Cancelled = 6,
}

/** Inputs to the payer-committed deal id (SPEC D10). */
export interface DealIdParams {
  /** The payer who will open the deal (must equal `msg.sender` at open time). */
  payer: Address;
  /** Caller-chosen salt that makes the id unique per deal. */
  salt: Hex;
  /** The settlement condition contract bound to the deal. */
  condition: Address;
  /** Deal amount in USDC atomic units (6 decimals). */
  amount: bigint;
  /** Absolute unix timestamp after which the payer may refund. */
  hardDeadline: bigint;
}

const DEAL_ID_ABI = [
  { type: "address" },
  { type: "bytes32" },
  { type: "address" },
  { type: "uint256" },
  { type: "uint256" },
] as const;

/**
 * Compute the payer-committed `dealId` (SPEC D10):
 * `keccak256(abi.encode(payer, salt, condition, amount, hardDeadline))`.
 *
 * This is the exact preimage the escrow recomputes in `open()`; the deposit must be credited to
 * this `dealId` and `open()` must be called by `payer`, or it reverts (front-running guard, T14).
 */
export function computeDealId(params: DealIdParams): Hex {
  return keccak256(
    encodeAbiParameters(DEAL_ID_ABI, [
      params.payer,
      params.salt,
      params.condition,
      params.amount,
      params.hardDeadline,
    ]),
  );
}
