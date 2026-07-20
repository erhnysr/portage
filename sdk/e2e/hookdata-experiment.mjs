// Isolate the hookData variable against the Gateway /v1/transfer 500.
// Runs two submits on the SAME existing deposit, full hookData FIRST (consumes nothing on 500),
// then empty "0x" hookData. No Arc RPC / no new deposit needed — just the public Gateway API.
//
//   node e2e/hookdata-experiment.mjs        (run from sdk/ after `npm run build`)

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { keccak256, toHex, pad } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { PortageClient, GatewayApi, PayoutAction, appIdFromName, accountIdFromName } from "../dist/index.js";

const here = dirname(fileURLToPath(import.meta.url));
for (const line of readFileSync(join(here, ".env.e2e"), "utf8").split("\n")) {
  const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
  if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
}

const account = privateKeyToAccount(process.env.TEST_EOA_PK);
const gatewayApi = new GatewayApi();
const portage = new PortageClient({ arcPublicClient: {}, gatewayApi }); // no Arc reads needed here

const appId = appIdFromName("coliseum");
const arenaAccount = accountIdFromName("arena-e2e-1");
const referenceId = keccak256(toHex(`entry-${Date.now()}`));
const payer = pad(account.address, { size: 32 });
const amount = 900000n; // 0.9 USDC, leaves headroom under the 1.0 balance

function buildIntent() {
  return portage.buildConsolidationIntent({
    sourceChain: "baseSepolia",
    amount,
    depositor: account.address,
    meta: { appId, account: arenaAccount, action: PayoutAction.EntryFee, referenceId, payer },
  });
}

async function trySubmit(label, mutate) {
  const intent = buildIntent();
  if (mutate) mutate(intent);
  const hd = intent.message.spec.hookData;
  console.log(`\n===== ${label} =====`);
  console.log(`hookData length: ${(hd.length - 2) / 2} bytes  value: ${hd.slice(0, 42)}${hd.length > 42 ? "…" : ""}`);
  const signature = await account.signTypedData(intent.typedData);
  try {
    const res = await gatewayApi.submitTransfer(intent.message, signature);
    console.log(`RESULT: ✅ SUCCESS  transferId=${res.transferId}  attestation=${res.attestation?.slice(0, 20)}…`);
    return true;
  } catch (e) {
    console.log(`RESULT: ❌ ${String(e.message || e).slice(0, 200)}`);
    return false;
  }
}

process.env.PORTAGE_DEBUG = "1"; // print the exact payload

// 1) full 192-byte PayoutMeta hookData — expect the 500 if hookData is the culprit.
await trySubmit("A: FULL hookData (192-byte PayoutMeta)", null);

// 2) empty hookData — expect success if the culprit is confirmed.
await trySubmit("B: EMPTY hookData (0x)", (intent) => {
  intent.message.spec.hookData = "0x";
  intent.typedData.message.spec.hookData = "0x";
});
