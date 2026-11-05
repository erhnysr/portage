/**
 * Consolidate 1 USDC from Base Sepolia into an app balance on Arc Testnet.
 *
 *   DEPOSITOR_KEY=0x...  holds Base Sepolia USDC + a little Base Sepolia ETH for gas
 *   RELAYER_KEY=0x...    any Arc Testnet key with a little USDC for gas (optional; defaults to DEPOSITOR_KEY)
 *   npm run consolidate
 *
 * Flow: deposit into Circle Gateway → sign the burn intent and the PayoutMeta binding →
 * Gateway attestation → one atomic mint-and-credit on Arc.
 */
import { createPublicClient, createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arcTestnet, baseSepolia } from "viem/chains";
import {
  PortageClient,
  PayoutAction,
  appIdFromName,
  accountIdFromName,
  addressToBytes32,
  type PayoutMeta,
} from "@erhnysr/portage-sdk";

const depositorKey = process.env.DEPOSITOR_KEY as Hex | undefined;
const relayerKey = (process.env.RELAYER_KEY ?? process.env.DEPOSITOR_KEY) as Hex | undefined;
if (!depositorKey || !relayerKey) throw new Error("Set DEPOSITOR_KEY (and optionally RELAYER_KEY)");

const AMOUNT = 1_000_000n; // 1 USDC (6 decimals)

const depositor = privateKeyToAccount(depositorKey);
const relayer = privateKeyToAccount(relayerKey);

const arcPublic = createPublicClient({ chain: arcTestnet, transport: http() });
const basePublic = createPublicClient({ chain: baseSepolia, transport: http() });
const baseWallet = createWalletClient({ chain: baseSepolia, transport: http(), account: depositor });
const arcWallet = createWalletClient({ chain: arcTestnet, transport: http(), account: relayer });

const portage = new PortageClient({ arcPublicClient: arcPublic, network: "arcTestnet" });

// How this deposit is credited on Arc: app "portage-demo", sub-account "quickstart".
const meta: PayoutMeta = {
  appId: appIdFromName("portage-demo"),
  account: accountIdFromName("quickstart"),
  action: PayoutAction.Credit,
  referenceId: accountIdFromName(`qs-${Date.now()}`),
  payer: addressToBytes32(depositor.address),
};

// 1. Build the burn intent first: it fixes maxFee, the most the Gateway transfer may charge
//    (SDK default: 10% of the amount, capped at 2.01 USDC). The deposit must cover amount + maxFee.
const intent = portage.buildConsolidationIntent({
  sourceChain: "baseSepolia",
  amount: AMOUNT,
  depositor: depositor.address,
});
const needed = AMOUNT + intent.message.maxFee;

// 2. Deposit into the Gateway unified balance (approve + deposit; waits out RPC lag).
const { depositTx } = await portage.deposit(baseWallet, {
  chain: "baseSepolia",
  amount: needed,
  sourcePublicClient: basePublic,
});
console.log("deposit:", `${baseSepolia.blockExplorers.default.url}/tx/${depositTx}`);

// 3. Wait for Circle to finalize the deposit (its balance lags the onchain tx).
await portage.waitForGatewayBalance(depositor.address, "baseSepolia", needed);

// 4. Sign the burn intent, then bind the PayoutMeta to its spec hash.
const burnSig = await baseWallet.signTypedData({ account: depositor, ...intent.typedData });
const metaSig = await baseWallet.signTypedData({
  account: depositor,
  ...portage.buildMetaBinding(portage.specHash(intent), meta),
});

// 5. Gateway attestation for Arc.
const { attestation, signature } = await portage.submitConsolidation(intent, burnSig);

// 6. Atomic mint + credit on Arc (anyone can relay; the forwarder checks the meta signature).
const creditTx = await portage.executeMintWithMeta(arcWallet, { attestation, signature, meta, metaSig });
console.log("credit:", `${portage.network.arc.explorerTx}${creditTx}`);

console.log("app balance (atomic USDC):", await portage.getAppBalance(meta.appId, meta.account));
