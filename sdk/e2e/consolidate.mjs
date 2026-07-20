// Portage end-to-end smoke test: Base Sepolia USDC -> Arc "coliseum" ledger.
// Run from the sdk/ directory (after `npm run build`):  node e2e/consolidate.mjs
//
// Flow: deposit to Gateway (Base Sepolia) -> build+sign burn intent -> submit to Gateway API
//       -> executeMint on Arc -> verify Ledger credit + router-at-rest + custody invariant.
//
// Requires (from e2e/.env.e2e or the environment):
//   TEST_EOA_PK, ARC_RPC_URL, BASE_SEPOLIA_RPC_URL, AMOUNT_USDC

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  erc20Abi,
  formatUnits,
  keccak256,
  toHex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import {
  PortageClient,
  GatewayApi,
  PayoutAction,
  appIdFromName,
  accountIdFromName,
  addressToBytes32,
  PORTAGE_ARC_TESTNET,
  ARC,
  GATEWAY,
} from "../dist/index.js";

// ---- tiny .env.e2e loader (no dependency) ----
const here = dirname(fileURLToPath(import.meta.url));
try {
  for (const line of readFileSync(join(here, ".env.e2e"), "utf8").split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
} catch {}

const { TEST_EOA_PK, ARC_RPC_URL, BASE_SEPOLIA_RPC_URL, AMOUNT_USDC = "1" } = process.env;
if (!TEST_EOA_PK || !ARC_RPC_URL) throw new Error("Set TEST_EOA_PK and ARC_RPC_URL (see e2e/.env.e2e)");
if (ARC_RPC_URL.includes("REPLACE_WITH_YOUR_KEY")) throw new Error("Set a real ARC_RPC_URL key in e2e/.env.e2e");

const amount = BigInt(Math.round(parseFloat(AMOUNT_USDC) * 1e6)); // USDC has 6 decimals
const account = privateKeyToAccount(TEST_EOA_PK);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = (...a) => console.log(...a);

const arcTestnet = defineChain({
  id: ARC.chainId,
  name: "Arc Testnet",
  nativeCurrency: { name: "USD Coin", symbol: "USDC", decimals: 6 },
  rpcUrls: { default: { http: [ARC_RPC_URL] } },
});

const baseWallet = createWalletClient({ account, chain: baseSepolia, transport: http(BASE_SEPOLIA_RPC_URL) });
const basePublic = createPublicClient({ chain: baseSepolia, transport: http(BASE_SEPOLIA_RPC_URL) });
const arcWallet = createWalletClient({ account, chain: arcTestnet, transport: http(ARC_RPC_URL) });
const arcPublic = createPublicClient({ chain: arcTestnet, transport: http(ARC_RPC_URL) });

const gatewayApi = new GatewayApi();
const portage = new PortageClient({ arcPublicClient: arcPublic, gatewayApi });

const appId = appIdFromName("coliseum");
const arenaAccount = accountIdFromName("arena-e2e-1");
const referenceId = keccak256(toHex(`entry-${Date.now()}`));
const payer = addressToBytes32(account.address);
const meta = { appId, account: arenaAccount, action: PayoutAction.EntryFee, referenceId, payer };

log("== Portage E2E: Base Sepolia -> Arc coliseum ==");
log("test EOA     :", account.address);
log("amount       :", formatUnits(amount, 6), "USDC");
log("appId        :", appId);
log("arenaAccount :", arenaAccount);
log("referenceId  :", referenceId);
log("router       :", PORTAGE_ARC_TESTNET.router);
log("");

// ---- 0. preflight balances ----
const usdcBase = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const [baseUsdc, baseEth, arcGas] = await Promise.all([
  basePublic.readContract({ address: usdcBase, abi: erc20Abi, functionName: "balanceOf", args: [account.address] }),
  basePublic.getBalance({ address: account.address }),
  arcPublic.getBalance({ address: account.address }),
]);
log(`preflight: Base USDC=${formatUnits(baseUsdc, 6)}  Base ETH=${formatUnits(baseEth, 18)}  Arc gas(USDC)=${formatUnits(arcGas, 6)}`);
if (baseUsdc < amount) throw new Error("test EOA has insufficient Base Sepolia USDC — fund via faucet.circle.com");
if (baseEth === 0n) throw new Error("test EOA has no Base Sepolia ETH for gas — fund via a Base Sepolia ETH faucet");
if (arcGas === 0n) throw new Error("test EOA has no Arc USDC for gas — fund Arc Testnet USDC via faucet.circle.com");

const ledgerBefore = await portage.getAppBalance(appId, arenaAccount);
log("ledger balance before:", formatUnits(ledgerBefore, 6), "USDC\n");

// ---- 1. deposit into Gateway on Base Sepolia ----
log("[1] approve + deposit to GatewayWallet on Base Sepolia...");
const { approveTx, depositTx } = await portage.deposit(baseWallet, {
  chain: "baseSepolia",
  amount,
  sourcePublicClient: basePublic,
});
log("    approve tx:", approveTx);
await basePublic.waitForTransactionReceipt({ hash: depositTx });
log("    deposit tx:", depositTx, "(confirmed)\n");

// ---- 2. build + sign the consolidation burn intent (empty hookData) + the meta binding ----
log("[2] build + sign consolidation intent (empty hookData) and PayoutMeta binding...");
const intent = portage.buildConsolidationIntent({ sourceChain: "baseSepolia", amount, depositor: account.address });
const signature = await baseWallet.signTypedData({ account, ...intent.typedData });

const specHash = portage.specHash(intent);
const metaBinding = portage.buildMetaBinding(specHash, meta);
const metaSig = await baseWallet.signTypedData({ account, ...metaBinding });
log("    burn intent signed. salt:", intent.salt);
log("    specHash:", specHash, "meta binding signed.\n");

// ---- 3. submit to Gateway API (retry until the deposit is observed / attested) ----
log("[3] submit to Gateway API (may retry until deposit finalizes)...");
let transfer;
for (let i = 1; i <= 20; i++) {
  try {
    transfer = await portage.submitConsolidation(intent, signature);
    if (transfer.attestation && transfer.attestation !== "0x") break;
    log(`    attempt ${i}: transferId=${transfer.transferId}, awaiting attestation...`);
  } catch (e) {
    log(`    attempt ${i}: ${String(e.message || e).slice(0, 140)}`);
  }
  await sleep(6000);
}
if (!transfer?.attestation || transfer.attestation === "0x") {
  // poll the transfer record if we have an id
  if (transfer?.transferId) {
    for (let i = 1; i <= 30; i++) {
      const rec = await gatewayApi.getTransfer(transfer.transferId);
      if (rec.attestation && rec.signature) {
        transfer = { ...transfer, attestation: rec.attestation, signature: rec.signature };
        break;
      }
      log(`    poll ${i}: status=${rec.status ?? rec.state}`);
      await sleep(6000);
    }
  }
}
if (!transfer?.attestation || transfer.attestation === "0x") throw new Error("no attestation received");
log("    attestation received. transferId:", transfer.transferId, "\n");

// ---- 4. executeMintWithMeta on Arc (atomic mint + credit, meta authorized by depositor sig) ----
log("[4] executeMintWithMeta on Arc (atomic mint + credit)...");
const mintTx = await portage.executeMintWithMeta(arcWallet, {
  attestation: transfer.attestation,
  signature: transfer.signature,
  meta,
  metaSig,
});
await arcPublic.waitForTransactionReceipt({ hash: mintTx });
log("    mint tx:", mintTx, "(confirmed)\n");

// ---- 5. verify ----
log("[5] verify on Arc...");
const ledgerAfter = await portage.getAppBalance(appId, arenaAccount);
const appTotal = await portage.getAppTotal(appId);
const routerUsdc = await arcPublic.readContract({
  address: ARC.usdc,
  abi: erc20Abi,
  functionName: "balanceOf",
  args: [PORTAGE_ARC_TESTNET.router],
});
const custody = await arcPublic.readContract({
  address: PORTAGE_ARC_TESTNET.ledger,
  abi: [{ type: "function", name: "custodyTotal", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] }],
  functionName: "custodyTotal",
});

const delta = ledgerAfter - ledgerBefore;
log("    ledger balance after :", formatUnits(ledgerAfter, 6), "USDC  (delta", formatUnits(delta, 6) + ")");
log("    app total            :", formatUnits(appTotal, 6), "USDC");
log("    router USDC at rest   :", formatUnits(routerUsdc, 6), "USDC  (expect 0)");
log("    custodyTotal          :", formatUnits(custody, 6), "USDC");

const ok =
  delta > 0n &&
  routerUsdc === 0n &&
  custody === appTotal;
log("");
log(ok ? "✅ E2E PASS: credited, router at rest = 0, custody == appTotal" : "❌ E2E CHECK FAILED — inspect above");

log("\nIndependent cast verification:");
log(`  cast call ${PORTAGE_ARC_TESTNET.ledger} 'balanceOf(bytes32,bytes32)(uint256)' ${appId} ${arenaAccount} --rpc-url "$ARC_RPC_URL"`);
log(`  cast call ${ARC.usdc} 'balanceOf(address)(uint256)' ${PORTAGE_ARC_TESTNET.router} --rpc-url "$ARC_RPC_URL"`);
log(`  cast call ${PORTAGE_ARC_TESTNET.ledger} 'custodyTotal()(uint256)' --rpc-url "$ARC_RPC_URL"`);
if (!ok) process.exit(1);
