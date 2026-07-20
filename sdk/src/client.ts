import {
  erc20Abi,
  type Account,
  type Address,
  type Hex,
  type Hash,
  type PublicClient,
  type WalletClient,
} from "viem";
import { ARC, GATEWAY, PORTAGE_ARC_TESTNET, SOURCE_CHAINS, sourceChainUsdc, type SourceChain } from "./config.js";
import { gatewayWalletAbi, ledgerAbi, mintForwarderAbi } from "./abis.js";
import { GatewayApi, type GatewayBalances } from "./gatewayApi.js";
import {
  buildConsolidationIntent as buildIntent,
  transferSpecHash,
  type BuildConsolidationParams,
  type ConsolidationIntent,
} from "./burnIntent.js";
import { payoutMetaTuple, type PayoutMeta } from "./payoutMeta.js";

/** EIP-712 type binding a PayoutMeta to a transfer's specHash (matches PortageMintForwarder). */
export const META_BINDING_TYPES = {
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

export interface PortageContracts {
  router: Address;
  forwarder: Address;
  ledger: Address;
}

export interface PortageClientConfig {
  /** Public client connected to Arc Testnet (for ledger reads / executeMint). */
  arcPublicClient: PublicClient;
  /** Portage contract addresses; defaults to the Arc Testnet v0.1 deployment. */
  contracts?: Partial<PortageContracts>;
  /** Gateway HTTP API client; defaults to the testnet endpoint. */
  gatewayApi?: GatewayApi;
}

function requireAccount(wc: WalletClient): Account {
  if (!wc.account) throw new Error("walletClient has no account bound");
  return wc.account;
}

/**
 * Non-custodial client SDK. Users sign burn intents with their own EOA (via any viem walletClient);
 * the SDK never holds keys. Covers: deposit → build/submit consolidation intent → executeMint,
 * plus balance reads.
 */
export class PortageClient {
  readonly contracts: PortageContracts;
  readonly gatewayApi: GatewayApi;
  private readonly arc: PublicClient;

  constructor(config: PortageClientConfig) {
    this.arc = config.arcPublicClient;
    this.contracts = {
      router: config.contracts?.router ?? PORTAGE_ARC_TESTNET.router,
      forwarder: config.contracts?.forwarder ?? PORTAGE_ARC_TESTNET.mintForwarder,
      ledger: config.contracts?.ledger ?? PORTAGE_ARC_TESTNET.ledger,
    };
    this.gatewayApi = config.gatewayApi ?? new GatewayApi();
  }

  // ------------------------------------------------------------------
  // Deposit into the Gateway unified balance (on the source chain)
  // ------------------------------------------------------------------

  /**
   * Approve the GatewayWallet to spend USDC on the source chain. Send this before {depositToGateway}.
   */
  async approveGateway(walletClient: WalletClient, params: { chain: SourceChain; amount: bigint }): Promise<Hash> {
    return walletClient.writeContract({
      address: sourceChainUsdc(params.chain),
      abi: erc20Abi,
      functionName: "approve",
      args: [GATEWAY.wallet, params.amount],
      account: requireAccount(walletClient),
      chain: walletClient.chain,
    });
  }

  /** Deposit USDC into the GatewayWallet (adds to the unified balance). Approve first. */
  async depositToGateway(walletClient: WalletClient, params: { chain: SourceChain; amount: bigint }): Promise<Hash> {
    return walletClient.writeContract({
      address: GATEWAY.wallet,
      abi: gatewayWalletAbi,
      functionName: "deposit",
      args: [sourceChainUsdc(params.chain), params.amount],
      account: requireAccount(walletClient),
      chain: walletClient.chain,
    });
  }

  /**
   * Convenience: approve then deposit. If `sourcePublicClient` is provided, waits for the approve
   * receipt AND polls the on-chain allowance until it is actually visible before depositing. The
   * allowance poll matters on load-balanced public RPCs (e.g. sepolia.base.org), which are
   * eventually consistent: a receipt can confirm on one node while the next gas-estimation read
   * hits a lagging node that still reports the old allowance — which would revert the deposit.
   */
  async deposit(
    walletClient: WalletClient,
    params: { chain: SourceChain; amount: bigint; sourcePublicClient?: PublicClient },
  ): Promise<{ approveTx: Hash; depositTx: Hash }> {
    const owner = requireAccount(walletClient).address;
    const approveTx = await this.approveGateway(walletClient, params);

    if (params.sourcePublicClient) {
      const receipt = await params.sourcePublicClient.waitForTransactionReceipt({ hash: approveTx });
      if (receipt.status !== "success") throw new Error(`approve tx reverted: ${approveTx}`);
      await this.waitForAllowance(
        params.sourcePublicClient,
        sourceChainUsdc(params.chain),
        owner,
        GATEWAY.wallet,
        params.amount,
      );
    }

    const depositTx = await this.depositToGateway(walletClient, params);
    return { approveTx, depositTx };
  }

  /** Polls the ERC20 allowance until it is at least `min` (handles eventually-consistent RPCs). */
  async waitForAllowance(
    publicClient: PublicClient,
    token: Address,
    owner: Address,
    spender: Address,
    min: bigint,
    opts: { tries?: number; delayMs?: number } = {},
  ): Promise<bigint> {
    const tries = opts.tries ?? 20;
    const delayMs = opts.delayMs ?? 2000;
    for (let i = 0; i < tries; i++) {
      const allowance = await publicClient.readContract({
        address: token,
        abi: erc20Abi,
        functionName: "allowance",
        args: [owner, spender],
      });
      if (allowance >= min) return allowance;
      await new Promise((r) => setTimeout(r, delayMs));
    }
    throw new Error(`allowance for ${spender} did not reach ${min} in time (RPC lag or approve failed)`);
  }

  // ------------------------------------------------------------------
  // Consolidation (burn intent → attestation → mint on Arc)
  // ------------------------------------------------------------------

  /** Build the EIP-712 consolidation intent, injecting this client's router/forwarder addresses. */
  buildConsolidationIntent(
    params: Omit<BuildConsolidationParams, "router" | "forwarder">,
  ): ConsolidationIntent {
    return buildIntent({ ...params, router: this.contracts.router, forwarder: this.contracts.forwarder });
  }

  /** The Gateway spec hash for an intent — the id PayoutMeta is bound to (computed off-chain). */
  specHash(intent: ConsolidationIntent): Hex {
    return transferSpecHash(intent.message.spec);
  }

  /**
   * Build the EIP-712 PayoutMetaBinding typed data. The depositor signs this to authorize `meta`
   * for the transfer identified by `specHash`; the forwarder verifies the signature came from the
   * attestation's sourceDepositor before crediting. Sign with walletClient.signTypedData().
   */
  buildMetaBinding(specHash: Hex, meta: PayoutMeta) {
    const [schema, appId, account, action, referenceId, payer] = payoutMetaTuple(meta);
    return {
      domain: {
        name: "Portage",
        version: "1",
        chainId: ARC.chainId,
        verifyingContract: this.contracts.forwarder,
      },
      types: META_BINDING_TYPES,
      primaryType: "PayoutMetaBinding" as const,
      message: { specHash, schema, appId, account, action, referenceId, payer },
    };
  }

  /** Submit a signed burn intent to the Gateway API and get the attestation for Arc. */
  async submitConsolidation(intent: ConsolidationIntent, signature: Hex) {
    return this.gatewayApi.submitTransfer(intent.message, signature);
  }

  /**
   * PRIMARY (v0.1): execute the atomic mint + credit on Arc with PayoutMeta delivered separately
   * and authorized by the depositor's meta-binding signature. Any caller (typically a relayer)
   * can send it — the burn intent's destinationCaller pins execution to the forwarder.
   */
  async executeMintWithMeta(
    walletClient: WalletClient,
    params: { attestation: Hex; signature: Hex; meta: PayoutMeta; metaSig: Hex },
  ): Promise<Hash> {
    const [schema, appId, account, action, referenceId, payer] = payoutMetaTuple(params.meta);
    return walletClient.writeContract({
      address: this.contracts.forwarder,
      abi: mintForwarderAbi,
      functionName: "executeMintWithMeta",
      args: [
        params.attestation,
        params.signature,
        { schema, appId, account, action, referenceId, payer },
        params.metaSig,
      ],
      account: requireAccount(walletClient),
      chain: walletClient.chain,
    });
  }

  /**
   * FORWARD-COMPAT: forwarder.executeMint(attestation, signature), reading PayoutMeta from the
   * attestation's own hookData. Only usable once Gateway carries non-empty hookData end to end.
   */
  async executeMint(
    walletClient: WalletClient,
    params: { attestation: Hex; signature: Hex },
  ): Promise<Hash> {
    return walletClient.writeContract({
      address: this.contracts.forwarder,
      abi: mintForwarderAbi,
      functionName: "executeMint",
      args: [params.attestation, params.signature],
      account: requireAccount(walletClient),
      chain: walletClient.chain,
    });
  }

  // ------------------------------------------------------------------
  // Reads
  // ------------------------------------------------------------------

  /** Portage ledger balance for an app sub-account on Arc. */
  async getAppBalance(appId: Hex, account: Hex): Promise<bigint> {
    return this.arc.readContract({
      address: this.contracts.ledger,
      abi: ledgerAbi,
      functionName: "balanceOf",
      args: [appId, account],
    });
  }

  /** Total Portage ledger balance across all of an app's sub-accounts on Arc. */
  async getAppTotal(appId: Hex): Promise<bigint> {
    return this.arc.readContract({
      address: this.contracts.ledger,
      abi: ledgerAbi,
      functionName: "appBalance",
      args: [appId],
    });
  }

  /** Gateway unified USDC balance for a depositor across source-chain domains. */
  async getUnifiedBalance(depositor: Address, opts?: { sourceChains?: SourceChain[] }): Promise<GatewayBalances> {
    const chains = opts?.sourceChains ?? (Object.keys(SOURCE_CHAINS) as SourceChain[]);
    const sources = chains.map((c) => ({ domain: SOURCE_CHAINS[c].domain, depositor }));
    return this.gatewayApi.getBalances("USDC", sources);
  }
}

export const ARC_CHAIN_ID = ARC.chainId;
