import type { Account, Address, Hex, Hash, PublicClient, WalletClient } from "viem";
import { conditionAddress, getNetwork, type NetworkName } from "./config.js";
import { conditionalEscrowAbi } from "./abis.js";
import { DealState } from "./deals.js";

export interface PortageEscrowConfig {
  /** Target network; defaults to Arc Testnet. Selecting an unpublished network throws. */
  network?: NetworkName;
  /**
   * ConditionalEscrow address. Defaults to the network's deployment, which is PENDING until the
   * layer is deployed (SPEC §10.11) — pass an explicit address until then, or the constructor throws.
   */
  conditionalEscrow?: Address;
  /** Wallet client on Arc for state-changing calls (open/claim/refund/cancel/sweep). */
  walletClient?: WalletClient;
  /** Arc public client for view reads (stateOf/allocationOf/…). */
  arcPublicClient?: PublicClient;
}

function requireAccount(wc: WalletClient): Account {
  if (!wc.account) throw new Error("walletClient has no account bound");
  return wc.account;
}

/** A resolved deal's snapshotted allocation. */
export interface Allocation {
  recipients: readonly Address[];
  amounts: readonly bigint[];
}

/**
 * Wrapper for `ConditionalEscrow` (SPEC §2.1). Writes require a `walletClient`; reads require an
 * `arcPublicClient`. Custody lives in the Portage Ledger — this contract holds no funds. Funding is
 * a Gateway deposit with `PayoutAction.EscrowFund` (see {computeDealId} for the deal id, D10); the
 * escrow verifies funding by reading the Ledger balance, so there is no on-chain "fund" call here.
 */
export class PortageEscrow {
  readonly address: Address;
  private readonly wallet?: WalletClient;
  private readonly arc?: PublicClient;

  constructor(config: PortageEscrowConfig) {
    this.address = config.conditionalEscrow ?? conditionAddress("conditionalEscrow", getNetwork(config.network));
    this.wallet = config.walletClient;
    this.arc = config.arcPublicClient;
  }

  private requireWallet(): WalletClient {
    if (!this.wallet) throw new Error("walletClient required for a state-changing call");
    return this.wallet;
  }

  private requireArc(): PublicClient {
    if (!this.arc) throw new Error("arcPublicClient required for a read call");
    return this.arc;
  }

  private write(functionName: string, args: readonly unknown[]): Promise<Hash> {
    const wallet = this.requireWallet();
    return wallet.writeContract({
      address: this.address,
      abi: conditionalEscrowAbi,
      functionName: functionName as never,
      args: args as never,
      account: requireAccount(wallet),
      chain: wallet.chain,
    });
  }

  // ------------------------------------------------------------------ writes

  /**
   * Open a deal against funds already credited to `Ledger.balances[appId][dealId]`. Must be sent by
   * `payer`, and `dealId` must equal {computeDealId}({payer, salt, condition, amount, hardDeadline}).
   */
  open(params: {
    appId: Hex;
    dealId: Hex;
    payer: Address;
    salt: Hex;
    condition: Address;
    amount: bigint;
    hardDeadline: bigint;
    participants: Address[];
  }): Promise<Hash> {
    return this.write("open", [
      params.appId,
      params.dealId,
      params.payer,
      params.salt,
      params.condition,
      params.amount,
      params.hardDeadline,
      params.participants,
    ]);
  }

  /** Funded → Resolving. Optional marker that the condition is running. */
  activate(dealId: Hex): Promise<Hash> {
    return this.write("activate", [dealId]);
  }

  /** Read the condition once and snapshot the allocation (Funded/Resolving → Resolved). */
  resolve(dealId: Hex): Promise<Hash> {
    return this.write("resolve", [dealId]);
  }

  /** Pull the caller's snapshotted allocation (Resolved → Claimed when the last recipient claims). */
  claim(dealId: Hex): Promise<Hash> {
    return this.write("claim", [dealId]);
  }

  /** Payer recovery after `hardDeadline` with no resolution (makes no call into the condition). */
  refund(dealId: Hex): Promise<Hash> {
    return this.write("refund", [dealId]);
  }

  /** Unanimous pre-resolution unwind (each of payer + participants calls once). */
  cancel(dealId: Hex): Promise<Hash> {
    return this.write("cancel", [dealId]);
  }

  /** Governor-only recovery of unaccounted surplus for `(appId, account)`. */
  sweepUnaccounted(params: { appId: Hex; account: Hex; to: Address }): Promise<Hash> {
    return this.write("sweepUnaccounted", [params.appId, params.account, params.to]);
  }

  // ------------------------------------------------------------------ reads

  private read<T>(functionName: string, args: readonly unknown[]): Promise<T> {
    return this.requireArc().readContract({
      address: this.address,
      abi: conditionalEscrowAbi,
      functionName: functionName as never,
      args: args as never,
    }) as Promise<T>;
  }

  async stateOf(dealId: Hex): Promise<DealState> {
    return (await this.read<number>("stateOf", [dealId])) as DealState;
  }

  appIdOf(dealId: Hex): Promise<Hex> {
    return this.read<Hex>("appIdOf", [dealId]);
  }

  payerOf(dealId: Hex): Promise<Address> {
    return this.read<Address>("payerOf", [dealId]);
  }

  conditionOf(dealId: Hex): Promise<Address> {
    return this.read<Address>("conditionOf", [dealId]);
  }

  dealAmount(dealId: Hex): Promise<bigint> {
    return this.read<bigint>("dealAmount", [dealId]);
  }

  hardDeadlineOf(dealId: Hex): Promise<bigint> {
    return this.read<bigint>("hardDeadlineOf", [dealId]);
  }

  participantsOf(dealId: Hex): Promise<readonly Address[]> {
    return this.read<readonly Address[]>("participantsOf", [dealId]);
  }

  async allocationOf(dealId: Hex): Promise<Allocation> {
    const [recipients, amounts] = await this.read<[readonly Address[], readonly bigint[]]>("allocationOf", [dealId]);
    return { recipients, amounts };
  }

  claimedOf(dealId: Hex, recipient: Address): Promise<boolean> {
    return this.read<boolean>("claimedOf", [dealId, recipient]);
  }

  /** Live principal owed for `(appId, account)`; the sweep-safe floor (D12/I20). */
  outstanding(appId: Hex, account: Hex): Promise<bigint> {
    return this.read<bigint>("outstanding", [appId, account]);
  }
}
