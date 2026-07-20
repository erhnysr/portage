import type { Address, Hex } from "viem";
import { GATEWAY } from "./config.js";
import type { BurnIntentMessage } from "./burnIntent.js";

export interface TransferResult {
  attestation: Hex;
  signature: Hex;
  transferId: string;
  fees?: unknown;
}

export interface GatewayBalanceSource {
  domain: number;
  depositor: Address;
}

export interface GatewayBalances {
  token: string;
  balances: Array<{ domain: number; depositor: string; balance: string }>;
}

/** Thin client over Circle's Gateway testnet HTTP API. */
export class GatewayApi {
  constructor(private readonly baseUrl: string = GATEWAY.apiTestnet) {}

  /** POST /v1/transfer — submit a signed burn intent, receive an attestation for the destination. */
  async submitTransfer(message: BurnIntentMessage, signature: Hex): Promise<TransferResult> {
    const payload = [
      {
        burnIntent: {
          maxBlockHeight: message.maxBlockHeight.toString(),
          maxFee: message.maxFee.toString(),
          spec: { ...message.spec, value: message.spec.value.toString() },
        },
        signature,
      },
    ];

    const env = (globalThis as { process?: { env?: Record<string, string | undefined> } }).process?.env;
    if (env?.PORTAGE_DEBUG) {
      console.error("[PORTAGE_DEBUG] POST /v1/transfer body:\n" + JSON.stringify(payload, null, 2));
    }

    const res = await this.post("/v1/transfer", payload);
    const result = Array.isArray(res) ? res[0] : res;
    return {
      attestation: result.attestation as Hex,
      signature: result.signature as Hex,
      transferId: result.transferId as string,
      fees: result.fees,
    };
  }

  /** GET /v1/transfers/{id} — poll for an attestation if it was not returned synchronously. */
  async getTransfer(transferId: string): Promise<Record<string, unknown>> {
    return this.get(`/v1/transfers/${transferId}`);
  }

  /** POST /v1/balances — unified balance across domains for a set of depositor addresses. */
  async getBalances(token: string, sources: GatewayBalanceSource[]): Promise<GatewayBalances> {
    return (await this.post("/v1/balances", { token, sources })) as GatewayBalances;
  }

  /** GET /v1/info — supported domains and contract addresses. */
  async getInfo(): Promise<Record<string, unknown>> {
    return this.get("/v1/info");
  }

  private async post(path: string, body: unknown): Promise<any> {
    const res = await fetch(`${this.baseUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`Gateway API ${path} failed: ${res.status} - ${await res.text()}`);
    return res.json();
  }

  private async get(path: string): Promise<any> {
    const res = await fetch(`${this.baseUrl}${path}`, { headers: { "Content-Type": "application/json" } });
    if (!res.ok) throw new Error(`Gateway API ${path} failed: ${res.status} - ${await res.text()}`);
    return res.json();
  }
}
