/**
 * Pay out from an app balance on Arc Testnet (server side).
 *
 *   CONTROLLER_KEY=0x...   the app's registered payoutController on Arc Testnet
 *   WINNER=0x...           recipient address
 *   npm run payout
 *
 * Every payout is scoped to one appId and carries a one-shot referenceId, so a retried
 * request can never pay twice.
 */
import { createPublicClient, createWalletClient, http, isAddress, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arcTestnet } from "viem/chains";
import { PortagePayouts, appIdFromName, accountIdFromName } from "@erhnysr/portage-sdk";

const controllerKey = process.env.CONTROLLER_KEY as Hex | undefined;
const winner = process.env.WINNER;
if (!controllerKey) throw new Error("Set CONTROLLER_KEY");
if (!winner || !isAddress(winner)) throw new Error("Set WINNER to a valid address");

const payouts = new PortagePayouts({
  appId: appIdFromName("portage-demo"),
  walletClient: createWalletClient({
    chain: arcTestnet,
    transport: http(),
    account: privateKeyToAccount(controllerKey),
  }),
  arcPublicClient: createPublicClient({ chain: arcTestnet, transport: http() }),
});

const referenceId = accountIdFromName("round-7"); // idempotency key for this payout

if (await payouts.isSettled(referenceId)) {
  console.log("already paid: nothing to do");
} else {
  const tx = await payouts.payout({
    account: accountIdFromName("quickstart"),
    referenceId,
    recipient: winner,
    amount: 500_000n, // 0.5 USDC
  });
  console.log("payout tx:", tx);
}
