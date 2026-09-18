import type { Abi, Account, Address, Hex, Hash, PublicClient, WalletClient } from "viem";
import { conditionAddress, getNetwork, type ConditionContract, type NetworkName } from "./config.js";
import {
  attestationConditionAbi,
  conditionRegistryAbi,
  mutualReleaseConditionAbi,
  timelockConditionAbi,
  verdictConditionAbi,
} from "./abis.js";

function requireAccount(wc: WalletClient): Account {
  if (!wc.account) throw new Error("walletClient has no account bound");
  return wc.account;
}

/** Shared config for a conditional-settlement contract wrapper. */
export interface ConditionWrapperConfig {
  /** Target network; defaults to Arc Testnet. */
  network?: NetworkName;
  /** Contract address. Defaults to the network's deployment (PENDING until §10.11 — pass explicit). */
  address?: Address;
  /** Wallet client on Arc for state-changing calls. */
  walletClient?: WalletClient;
  /** Arc public client for view reads. */
  arcPublicClient?: PublicClient;
}

/** A condition's `resolve()` output: whether it is settled and the snapshotted allocation. */
export interface ConditionResolution {
  settled: boolean;
  recipients: readonly Address[];
  amounts: readonly bigint[];
}

/** Common wiring shared by every condition wrapper (address resolution, read/write plumbing). */
abstract class ContractWrapper {
  readonly address: Address;
  protected readonly abi: Abi;
  protected readonly wallet?: WalletClient;
  protected readonly arc?: PublicClient;

  protected constructor(abi: Abi, key: ConditionContract, config: ConditionWrapperConfig) {
    this.abi = abi;
    this.address = config.address ?? conditionAddress(key, getNetwork(config.network));
    this.wallet = config.walletClient;
    this.arc = config.arcPublicClient;
  }

  protected write(functionName: string, args: readonly unknown[]): Promise<Hash> {
    if (!this.wallet) throw new Error("walletClient required for a state-changing call");
    return this.wallet.writeContract({
      address: this.address,
      abi: this.abi,
      functionName: functionName as never,
      args: args as never,
      account: requireAccount(this.wallet),
      chain: this.wallet.chain,
    });
  }

  protected read<T>(functionName: string, args: readonly unknown[]): Promise<T> {
    if (!this.arc) throw new Error("arcPublicClient required for a read call");
    return this.arc.readContract({
      address: this.address,
      abi: this.abi,
      functionName: functionName as never,
      args: args as never,
    }) as Promise<T>;
  }
}

/** Base for the four ISettlementCondition wrappers — they share `resolve(dealId)`. */
abstract class ConditionBase extends ContractWrapper {
  /** Read the condition's current outcome (view). settled=false until final. */
  async resolve(dealId: Hex): Promise<ConditionResolution> {
    const [settled, recipients, amounts] = await this.read<[boolean, readonly Address[], readonly bigint[]]>(
      "resolve",
      [dealId],
    );
    return { settled, recipients, amounts };
  }
}

/**
 * ConditionRegistry — governor-gated allowlist (D3/I9). `setApproved` must be sent by the governor
 * (the contract owner).
 */
export class PortageConditionRegistry extends ContractWrapper {
  constructor(config: ConditionWrapperConfig) {
    super(conditionRegistryAbi as unknown as Abi, "conditionRegistry", config);
  }

  /** Approve or revoke a condition (governor only; idempotent). */
  setApproved(condition: Address, approved: boolean): Promise<Hash> {
    return this.write("setApproved", [condition, approved]);
  }

  /** Whether a condition is currently approved for attachment. */
  isApproved(condition: Address): Promise<boolean> {
    return this.read<boolean>("isApproved", [condition]);
  }
}

/**
 * MutualReleaseCondition (SPEC §10.6) — every party (payer + participants) approves an identical
 * allocation; unanimity finalizes.
 */
export class MutualReleaseCondition extends ConditionBase {
  constructor(config: ConditionWrapperConfig) {
    super(mutualReleaseConditionAbi as unknown as Abi, "mutualReleaseCondition", config);
  }

  /** Sign off on `(recipients, amounts)` for a deal. */
  approve(params: { dealId: Hex; recipients: Address[]; amounts: bigint[] }): Promise<Hash> {
    return this.write("approve", [params.dealId, params.recipients, params.amounts]);
  }

  /** Whether unanimity has been reached (the deal is finalized). */
  finalized(dealId: Hex): Promise<boolean> {
    return this.read<boolean>("finalized", [dealId]);
  }
}

/**
 * TimelockCondition (SPEC §10.7) — the payer proposes an allocation and a soft deadline; if not
 * objected before it, the allocation becomes claimable.
 */
export class TimelockCondition extends ConditionBase {
  constructor(config: ConditionWrapperConfig) {
    super(timelockConditionAbi as unknown as Abi, "timelockCondition", config);
  }

  /** Payer proposes the timeout allocation and soft deadline (once). */
  initialize(params: { dealId: Hex; softDeadline: bigint; recipients: Address[]; amounts: bigint[] }): Promise<Hash> {
    return this.write("initialize", [params.dealId, params.softDeadline, params.recipients, params.amounts]);
  }

  /** Payer permanently blocks the timeout release (before the soft deadline). */
  object(dealId: Hex): Promise<Hash> {
    return this.write("object", [dealId]);
  }

  isInitialized(dealId: Hex): Promise<boolean> {
    return this.read<boolean>("isInitialized", [dealId]);
  }

  isObjected(dealId: Hex): Promise<boolean> {
    return this.read<boolean>("isObjected", [dealId]);
  }

  softDeadlineOf(dealId: Hex): Promise<bigint> {
    return this.read<bigint>("softDeadlineOf", [dealId]);
  }
}

/**
 * AttestationCondition (SPEC §10.8) — the payer names an attester who makes a single, final
 * attestation of the allocation.
 */
export class AttestationCondition extends ConditionBase {
  constructor(config: ConditionWrapperConfig) {
    super(attestationConditionAbi as unknown as Abi, "attestationCondition", config);
  }

  /** Payer names the attester (once). */
  initialize(params: { dealId: Hex; attester: Address }): Promise<Hash> {
    return this.write("initialize", [params.dealId, params.attester]);
  }

  /** The designated attester records the final allocation (once). */
  attest(params: { dealId: Hex; recipients: Address[]; amounts: bigint[] }): Promise<Hash> {
    return this.write("attest", [params.dealId, params.recipients, params.amounts]);
  }

  isInitialized(dealId: Hex): Promise<boolean> {
    return this.read<boolean>("isInitialized", [dealId]);
  }

  isAttested(dealId: Hex): Promise<boolean> {
    return this.read<boolean>("isAttested", [dealId]);
  }

  attesterOf(dealId: Hex): Promise<Address> {
    return this.read<Address>("attesterOf", [dealId]);
  }
}

/**
 * VerdictCondition (SPEC §10.9) — resolves from a finalized on-chain Arena verdict, mirroring the
 * arena's 60/30/10 split onto the deal amount.
 */
export class VerdictCondition extends ConditionBase {
  constructor(config: ConditionWrapperConfig) {
    super(verdictConditionAbi as unknown as Abi, "verdictCondition", config);
  }

  /** Payer binds the deal to an Arena (once). */
  initialize(params: { dealId: Hex; arena: Address }): Promise<Hash> {
    return this.write("initialize", [params.dealId, params.arena]);
  }

  initialized(dealId: Hex): Promise<boolean> {
    return this.read<boolean>("initialized", [dealId]);
  }

  arenaOf(dealId: Hex): Promise<Address> {
    return this.read<Address>("arenaOf", [dealId]);
  }
}
