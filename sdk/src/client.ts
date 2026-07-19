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
  type BuildConsolidationParams,
  type ConsolidationIntent,
} from "./burnIntent.js";

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
   * receipt before depositing (recommended to avoid nonce/allowance races).
   */
  async deposit(
    walletClient: WalletClient,
    params: { chain: SourceChain; amount: bigint; sourcePublicClient?: PublicClient },
  ): Promise<{ approveTx: Hash; depositTx: Hash }> {
    const approveTx = await this.approveGateway(walletClient, params);
    if (params.sourcePublicClient) {
      await params.sourcePublicClient.waitForTransactionReceipt({ hash: approveTx });
    }
    const depositTx = await this.depositToGateway(walletClient, params);
    return { approveTx, depositTx };
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

  /** Submit a signed burn intent to the Gateway API and get the attestation for Arc. */
  async submitConsolidation(intent: ConsolidationIntent, signature: Hex) {
    return this.gatewayApi.submitTransfer(intent.message, signature);
  }

  /**
   * Execute the mint on Arc: forwarder.executeMint(attestation, signature). This is the atomic
   * mint + credit step. Typically run by a relayer, but any caller works — the burn intent's
   * destinationCaller pins execution to the forwarder, so it cannot be front-run.
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
