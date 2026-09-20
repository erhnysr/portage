import { parseUnits, formatUnits } from "viem";

// Arc Testnet USDC (ERC-20 interface)
// IMPORTANT: ERC-20 USDC = 6 decimals. Native gas USDC = 18 decimals. Same asset, different precision.
export const USDC_ADDRESS = "0x3600000000000000000000000000000000000000" as `0x${string}`;
export const USDC_DECIMALS = 6;

/** Convert a human-readable USDC string to 6-decimal bigint. e.g. "0.10" → 100000n */
export function parseUsdc(amount: string): bigint {
  return parseUnits(amount, USDC_DECIMALS);
}

/** Format a 6-decimal USDC bigint to human-readable string. e.g. 100000n → "0.1" */
export function formatUsdc(amount: bigint): string {
  return formatUnits(amount, USDC_DECIMALS);
}

// Contract fee constants (6 decimals)
export const SUBMISSION_FEE = 100_000n; // 0.10 USDC
export const VOTE_STAKE = 50_000n;      // 0.05 USDC
