# @erhnysr/portage-sdk

TypeScript SDK for **Portage** — cross-chain USDC payout consolidation on Arc.

Two surfaces:
- **`PortageClient`** — non-custodial client. Users sign burn intents with their own EOA (any viem `walletClient`); the SDK never holds keys.
- **`PortagePayouts`** — server SDK for app backends. Authorizes payouts scoped to one `appId`, signed by that app's `payoutController`.

Config is network-keyed: `getNetwork(name)` resolves all Arc/Gateway/Portage facts for a
network, and both surfaces accept a `network?` option (defaults to `"arcTestnet"`). `"arcMainnet"`
selects the **capped mainnet pilot** (unaudited, kept to a few USDC; source chains `base`,
`ethereum`, `arbitrum`, `avalanche`). The conditional-settlement layer and the Arena are not on
mainnet yet. Unsupported source chains throw a clear error. The old flat exports
(`ARC`, `GATEWAY`, `PORTAGE_ARC_TESTNET`, `SOURCE_CHAINS`) remain as deprecated Arc Testnet aliases.

```bash
npm install @erhnysr/portage-sdk viem
```

## Client: consolidate USDC from Base Sepolia into an app's balance on Arc

```ts
import { createPublicClient, createWalletClient, custom, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arcTestnet, baseSepolia } from "viem/chains";
import {
  PortageClient,
  PayoutAction,
  appIdFromName,
  accountIdFromName,
  addressToBytes32,
} from "@erhnysr/portage-sdk";

const arc = createPublicClient({ chain: arcTestnet, transport: http() });
const portage = new PortageClient({ arcPublicClient: arc }); // network defaults to "arcTestnet"

// user's wallet on the source chain (Base Sepolia)
const wallet = createWalletClient({ chain: baseSepolia, transport: custom(window.ethereum) });
const [depositor] = await wallet.getAddresses();
const basePublic = createPublicClient({ chain: baseSepolia, transport: http() });

// the PayoutMeta describing how to credit this deposit (delivered out of band in v0.1)
const meta = {
  appId: appIdFromName("coliseum"),
  account: accountIdFromName("arena-1"),
  action: PayoutAction.EntryFee,
  referenceId: accountIdFromName("entry-42"),
  payer: addressToBytes32(depositor),
};

// 1. build the consolidation intent first: it fixes maxFee, the most the Gateway transfer may
//    charge (default 10% of the amount, capped at 2.01 USDC). Deposit must cover amount + maxFee.
const amount = 5_000000n; // 5 USDC (6 decimals)
const intent = portage.buildConsolidationIntent({ sourceChain: "baseSepolia", amount, depositor });
const needed = amount + intent.message.maxFee;

// 2. deposit into the Gateway unified balance, then wait for Circle to finalize it
await portage.deposit(wallet, { chain: "baseSepolia", amount: needed, sourcePublicClient: basePublic });
await portage.waitForGatewayBalance(depositor, "baseSepolia", needed);

// 3. sign the burn intent AND the PayoutMeta binding (bound to the transfer's specHash;
//    this is what keeps it non-custodial)
const burnSig = await wallet.signTypedData({ account: depositor, ...intent.typedData });
const metaSig = await wallet.signTypedData({
  account: depositor,
  ...portage.buildMetaBinding(portage.specHash(intent), meta),
});

// 4. submit the burn intent → attestation
const { attestation, signature: attSig } = await portage.submitConsolidation(intent, burnSig);

// 5. execute the atomic mint + credit on Arc (any relayer; the forwarder verifies the meta
//    was signed by the depositor before crediting). Arc uses USDC for gas.
const relayerAccount = privateKeyToAccount(process.env.RELAYER_KEY as Hex);
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
import { PortagePayouts, appIdFromName, accountIdFromName } from "@erhnysr/portage-sdk";

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
