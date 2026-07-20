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

// the PayoutMeta describing how to credit this deposit (delivered out of band in v0.1)
const meta = {
  appId: appIdFromName("coliseum"),
  account: accountIdFromName("arena-1"),
  action: PayoutAction.EntryFee,
  referenceId: accountIdFromName("entry-42"),
  payer: addressToBytes32(depositor),
};

// 1. deposit into the Gateway unified balance
await portage.deposit(wallet, { chain: "baseSepolia", amount: 5_000000n }); // 5 USDC (6 decimals)

// 2. build the consolidation intent (empty hookData) and sign both the burn intent AND the
//    PayoutMeta binding (bound to the transfer's specHash — this is what keeps it non-custodial)
const intent = portage.buildConsolidationIntent({ sourceChain: "baseSepolia", amount: 5_000000n, depositor });
const burnSig = await wallet.signTypedData({ account: depositor, ...intent.typedData });

const specHash = portage.specHash(intent);
const metaSig = await wallet.signTypedData({ account: depositor, ...portage.buildMetaBinding(specHash, meta) });

// 3. submit the burn intent → attestation
const { attestation, signature: attSig } = await portage.submitConsolidation(intent, burnSig);

// 4. execute the atomic mint + credit on Arc, passing the meta + its signature (relayer or self;
//    the forwarder verifies the meta was signed by the depositor before crediting)
const arcWallet = createWalletClient({ chain: arcTestnet, transport: http(), account: relayerAccount });
await portage.executeMintWithMeta(arcWallet, { attestation, signature: attSig, meta, metaSig });

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
- **PayoutMeta is delivered out of band in v0.1** (empty Gateway hookData) because the Circle Gateway testnet transfer API returns 500 on non-empty hookData (ARCHITECTURE.md §13). It is bound to the transfer's `specHash` by the depositor's EIP-712 signature (`buildMetaBinding`), which the forwarder verifies before crediting — so a relayer cannot misattribute a deposit. Unknown-app deposits are quarantined on the router, never mis-credited.
- Gateway does not execute hooks; `executeMintWithMeta` is Portage's own atomic composition (see ARCHITECTURE.md §12). `executeMint` (hookData path) remains for forward-compat.
