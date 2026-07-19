import type { Account, Address, Hex, Hash, PublicClient, WalletClient } from "viem";
import { PORTAGE_ARC_TESTNET } from "./config.js";
import { payoutEngineAbi } from "./abis.js";

export interface PortagePayoutsConfig {
  /** The app's bytes32 id (e.g. appIdFromName("coliseum")). */
  appId: Hex;
  /** Wallet client on Arc, signing as the app's registered payoutController. */
  walletClient: WalletClient;
  /** PayoutEngine address; defaults to the Arc Testnet v0.1 deployment. */
  payoutEngine?: Address;
  /** Optional Arc public client for settled() reads. */
  arcPublicClient?: PublicClient;
}

function requireAccount(wc: WalletClient): Account {
  if (!wc.account) throw new Error("walletClient has no account bound");
  return wc.account;
}

/**
 * Server SDK for app backends. Authorizes payouts against the app's own isolated Ledger balance;
 * every call is signed by the app's payoutController and scoped to `appId`. Holds no user funds.
 */
export class PortagePayouts {
  readonly appId: Hex;
  readonly payoutEngine: Address;
  private readonly wallet: WalletClient;
  private readonly arc?: PublicClient;

  constructor(config: PortagePayoutsConfig) {
    this.appId = config.appId;
    this.wallet = config.walletClient;
    this.payoutEngine = config.payoutEngine ?? PORTAGE_ARC_TESTNET.payoutEngine;
    this.arc = config.arcPublicClient;
  }

  /** Pay out a single recipient from an app sub-account. `referenceId` is a one-shot idempotency key. */
  async payout(params: {
    account: Hex;
    referenceId: Hex;
    recipient: Address;
    amount: bigint;
  }): Promise<Hash> {
    return this.wallet.writeContract({
      address: this.payoutEngine,
      abi: payoutEngineAbi,
      functionName: "payout",
      args: [this.appId, params.account, params.referenceId, params.recipient, params.amount],
      account: requireAccount(this.wallet),
      chain: this.wallet.chain,
    });
  }

  /** Batch payout (e.g. arena reward distribution). Whole-batch atomic: any failed debit reverts all. */
  async distribute(params: {
    account: Hex;
    referenceId: Hex;
    recipients: Address[];
    amounts: bigint[];
  }): Promise<Hash> {
    if (params.recipients.length !== params.amounts.length) {
      throw new Error("recipients and amounts length mismatch");
    }
    return this.wallet.writeContract({
      address: this.payoutEngine,
      abi: payoutEngineAbi,
      functionName: "distribute",
      args: [this.appId, params.account, params.referenceId, params.recipients, params.amounts],
      account: requireAccount(this.wallet),
      chain: this.wallet.chain,
    });
  }

  /** Whether a referenceId has already been settled for this app. */
  async isSettled(referenceId: Hex): Promise<boolean> {
    if (!this.arc) throw new Error("arcPublicClient required for isSettled()");
    return this.arc.readContract({
      address: this.payoutEngine,
      abi: payoutEngineAbi,
      functionName: "settled",
      args: [this.appId, referenceId],
    });
  }
}
