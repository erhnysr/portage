# @portage/sdk

TypeScript SDK for **Portage** — cross-chain USDC payout consolidation on Arc.

Two surfaces:
- **`PortageClient`** — non-custodial client. Users sign burn intents with their own EOA (any viem `walletClient`); the SDK never holds keys.
- **`PortagePayouts`** — server SDK for app backends. Authorizes payouts scoped to one `appId`, signed by that app's `payoutController`.

Defaults target the Arc Testnet v0.1 deployment (see `PORTAGE_ARC_TESTNET`).

```bash
npm install @portage/sdk viem
```

## Client: consolidate USDC from Base Sepolia into an app's balance on Arc

```ts
import { createPublicClient, createWalletClient, custom, http } from "viem";
import { arcTestnet, baseSepolia } from "./chains"; // your viem chain defs
import { PortageClient, PayoutAction, appIdFromName, accountIdFromName } from "@portage/sdk";

const arc = createPublicClient({ chain: arcTestnet, transport: http() });
const portage = new PortageClient({ arcPublicClient: arc });

// user's wallet on the source chain (Base Sepolia)
const wallet = createWalletClient({ chain: baseSepolia, transport: custom(window.ethereum) });
const [depositor] = await wallet.getAddresses();

// 1. deposit into the Gateway unified balance
await portage.deposit(wallet, { chain: "baseSepolia", amount: 5_000000n }); // 5 USDC (6 decimals)

// 2. build the consolidation intent (destinationRecipient/caller are injected from config)
const intent = portage.buildConsolidationIntent({
  sourceChain: "baseSepolia",
  amount: 5_000000n,
  depositor,
  meta: {
    appId: appIdFromName("coliseum"),
    account: accountIdFromName("arena-1"),
    action: PayoutAction.EntryFee,
    referenceId: accountIdFromName("entry-42"),
    payer: `0x${depositor.slice(2).padStart(64, "0")}`,
  },
});

// 3. sign (non-custodial) and submit → attestation
const signature = await wallet.signTypedData({ account: depositor, ...intent.typedData });
const { attestation, signature: attSig } = await portage.submitConsolidation(intent, signature);

// 4. execute the atomic mint + credit on Arc (relayer or self; pins to the forwarder)
const arcWallet = createWalletClient({ chain: arcTestnet, transport: http(), account: relayerAccount });
await portage.executeMint(arcWallet, { attestation, signature: attSig });

// reads
await portage.getAppBalance(appIdFromName("coliseum"), accountIdFromName("arena-1"));
await portage.getUnifiedBalance(depositor);
```

## Server: pay out from an app's balance

```ts
import { createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { PortagePayouts, appIdFromName, accountIdFromName } from "@portage/sdk";

const controller = privateKeyToAccount(process.env.COLISEUM_CONTROLLER_KEY as `0x${string}`);
const wallet = createWalletClient({ chain: arcTestnet, transport: http(), account: controller });

const payouts = new PortagePayouts({ appId: appIdFromName("coliseum"), walletClient: wallet });

// single payout
await payouts.payout({
  account: accountIdFromName("arena-1"),
  referenceId: accountIdFromName("round-7"),
  recipient: "0xWinner...",
  amount: 12_000000n,
});

// batch (whole-batch atomic)
await payouts.distribute({
  account: accountIdFromName("arena-1"),
  referenceId: accountIdFromName("round-7-final"),
  recipients: ["0xW1...", "0xW2..."],
  amounts: [8_000000n, 4_000000n],
});
```

## Notes

- Amounts are atomic USDC units (6 decimals): `5 USDC == 5_000000n`.
- `hookData` is the encoded `PayoutMeta`; it rides inside the Circle-signed TransferSpec, so it is tamper-evident. Malformed or unknown-app deposits are quarantined on the router, never mis-credited.
- Gateway does not execute hooks; `executeMint` is Portage's own atomic composition (see ARCHITECTURE.md §12).
