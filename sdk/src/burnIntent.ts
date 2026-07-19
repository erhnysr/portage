import { pad, toHex, maxUint256, type Address, type Hex } from "viem";
import { ARC, GATEWAY, sourceChainDomain, sourceChainUsdc, type SourceChain } from "./config.js";
import { encodePayoutMeta, type PayoutMeta } from "./payoutMeta.js";

/** EIP-712 domain used by Circle's GatewayWallet for burn intents (name + version only). */
export const GATEWAY_EIP712_DOMAIN = { name: "GatewayWallet", version: "1" } as const;

export const BURN_INTENT_TYPES = {
  TransferSpec: [
    { name: "version", type: "uint32" },
    { name: "sourceDomain", type: "uint32" },
    { name: "destinationDomain", type: "uint32" },
    { name: "sourceContract", type: "bytes32" },
    { name: "destinationContract", type: "bytes32" },
    { name: "sourceToken", type: "bytes32" },
    { name: "destinationToken", type: "bytes32" },
    { name: "sourceDepositor", type: "bytes32" },
    { name: "destinationRecipient", type: "bytes32" },
    { name: "sourceSigner", type: "bytes32" },
    { name: "destinationCaller", type: "bytes32" },
    { name: "value", type: "uint256" },
    { name: "salt", type: "bytes32" },
    { name: "hookData", type: "bytes" },
  ],
  BurnIntent: [
    { name: "maxBlockHeight", type: "uint256" },
    { name: "maxFee", type: "uint256" },
    { name: "spec", type: "TransferSpec" },
  ],
} as const;

export interface TransferSpecMessage {
  version: number;
  sourceDomain: number;
  destinationDomain: number;
  sourceContract: Hex;
  destinationContract: Hex;
  sourceToken: Hex;
  destinationToken: Hex;
  sourceDepositor: Hex;
  destinationRecipient: Hex;
  sourceSigner: Hex;
  destinationCaller: Hex;
  value: bigint;
  salt: Hex;
  hookData: Hex;
}

export interface BurnIntentMessage {
  maxBlockHeight: bigint;
  maxFee: bigint;
  spec: TransferSpecMessage;
}

export interface ConsolidationIntent {
  /** Ready to pass to walletClient.signTypedData(). */
  typedData: {
    domain: typeof GATEWAY_EIP712_DOMAIN;
    types: typeof BURN_INTENT_TYPES;
    primaryType: "BurnIntent";
    message: BurnIntentMessage;
  };
  /** The message alone, for submission to the Gateway API. */
  message: BurnIntentMessage;
  salt: Hex;
}

export interface BuildConsolidationParams {
  sourceChain: SourceChain;
  /** Atomic USDC units (6 decimals). */
  amount: bigint;
  /** The address that deposited to Gateway and holds the unified balance. */
  depositor: Address;
  /** The address that signs the burn intent; defaults to `depositor`. */
  signer?: Address;
  /** Portage router (destinationRecipient) and forwarder (destinationCaller). */
  router: Address;
  forwarder: Address;
  /** Payout metadata carried in hookData. */
  meta: PayoutMeta;
  /** Optional overrides. */
  salt?: Hex;
  maxFee?: bigint;
  maxBlockHeight?: bigint;
}

function addressToBytes32(address: Address): Hex {
  return pad(address.toLowerCase() as Hex, { size: 32 });
}

/** 32 random bytes for the transfer spec salt (keeps otherwise-identical transfers unique). */
export function randomSalt(): Hex {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return toHex(bytes);
}

/** Default Gateway fee ceiling: ~0.1–0.2% for larger transfers, 10% cap for dust. */
function defaultMaxFee(amount: bigint): bigint {
  return amount > 10_000_000n ? 2_010_000n : amount / 10n;
}

/**
 * Builds the EIP-712 burn intent that consolidates USDC from `sourceChain` into Portage on Arc.
 * The intent pins `destinationRecipient = router` and `destinationCaller = forwarder`, and carries
 * the encoded PayoutMeta in hookData. Sign `typedData` with the depositor/signer EOA, then submit
 * `message` to the Gateway API.
 */
export function buildConsolidationIntent(params: BuildConsolidationParams): ConsolidationIntent {
  const salt = params.salt ?? randomSalt();
  const signer = params.signer ?? params.depositor;

  const spec: TransferSpecMessage = {
    version: 1,
    sourceDomain: sourceChainDomain(params.sourceChain),
    destinationDomain: ARC.domain,
    sourceContract: addressToBytes32(GATEWAY.wallet),
    destinationContract: addressToBytes32(GATEWAY.minter),
    sourceToken: addressToBytes32(sourceChainUsdc(params.sourceChain)),
    destinationToken: addressToBytes32(ARC.usdc),
    sourceDepositor: addressToBytes32(params.depositor),
    destinationRecipient: addressToBytes32(params.router),
    sourceSigner: addressToBytes32(signer),
    destinationCaller: addressToBytes32(params.forwarder),
    value: params.amount,
    salt,
    hookData: encodePayoutMeta(params.meta),
  };

  const message: BurnIntentMessage = {
    maxBlockHeight: params.maxBlockHeight ?? maxUint256,
    maxFee: params.maxFee ?? defaultMaxFee(params.amount),
    spec,
  };

  return {
    typedData: { domain: GATEWAY_EIP712_DOMAIN, types: BURN_INTENT_TYPES, primaryType: "BurnIntent", message },
    message,
    salt,
  };
}
