#!/usr/bin/env node
// Portage mainnet pilot: one real Base -> Arc consolidation through the Portage contracts.
//
// Runs on the owner's machine with the owner's Foundry keystore. The key is decrypted in memory
// after a password prompt and is never written anywhere. Nothing here holds or forwards funds
// beyond the single capped transfer the owner starts.
//
// Usage (from the repo root, after `npm run build` in sdk/):
//   node sdk/scripts/mainnet-pilot.mjs status
//   node sdk/scripts/mainnet-pilot.mjs consolidate [amountUSDC=1]
//   node sdk/scripts/mainnet-pilot.mjs execute        # retry only the Arc step from saved state
//
// Env overrides (defaults are Arc mainnet + Base mainnet):
//   PORTAGE_KEYSTORE      path to the Foundry keystore (default ~/.foundry/keystores/deployer)
//   PORTAGE_DEPLOYMENT    path to the forge broadcast file (default broadcast/Deploy.s.sol/5042/run-latest.json)
//   PORTAGE_ARC_RPC, PORTAGE_BASE_RPC, PORTAGE_GATEWAY_API, PORTAGE_APP (default portage-demo)

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { scryptSync, pbkdf2Sync, createDecipheriv } from "node:crypto";
import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  concat,
  toHex,
  pad,
  parseUnits,
  formatUnits,
  maxUint256,
  getAddress,
  decodeEventLog,
  erc20Abi,
  parseAbi,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import {
  GatewayApi,
  transferSpecHash,
  BURN_INTENT_TYPES,
  GATEWAY_EIP712_DOMAIN,
  META_BINDING_TYPES,
  mintForwarderAbi,
  appIdFromName,
  accountIdFromName,
  payoutMetaTuple,
  PayoutAction,
} from "../dist/index.js";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");
const STATE_FILE = join(here, ".pilot-state.json");

// ---- Network facts (verified 2026-10-14 against gateway-api.circle.com/v1/info and on-chain) ----
const ARC_CHAIN_ID = 5042;
const ARC_DOMAIN = 26;
const BASE_DOMAIN = 6;
const ARC_USDC = "0x3600000000000000000000000000000000000000";
const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const GATEWAY_WALLET = "0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE";
const GATEWAY_MINTER = "0x2222222d7164433c4C09B0b0D809a9b52C04C205";
const EXPLORER = "https://explorer.arc.io";

const ARC_RPC = process.env.PORTAGE_ARC_RPC ?? "https://rpc.mainnet.arc.io";
const BASE_RPC = process.env.PORTAGE_BASE_RPC ?? "https://mainnet.base.org";
const GATEWAY_API = process.env.PORTAGE_GATEWAY_API ?? "https://gateway-api.circle.com";
const APP_NAME = process.env.PORTAGE_APP ?? "portage-demo";
const MAX_AMOUNT_USDC = 5; // pilot cap: refuse anything larger

const arcChain = {
  id: ARC_CHAIN_ID,
  name: "Arc",
  nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
  rpcUrls: { default: { http: [ARC_RPC] } },
  blockExplorers: { default: { name: "Arc Explorer", url: EXPLORER } },
};

const portageAbi = parseAbi([
  "function forwarder() view returns (address)",
  "function router() view returns (address)",
  "function gatewayMinter() view returns (address)",
  "function creditor() view returns (address)",
  "function isRegistered(bytes32) view returns (bool)",
  "function balanceOf(bytes32 appId, bytes32 account) view returns (uint256)",
  "function appBalance(bytes32 appId) view returns (uint256)",
  "function custodyTotal() view returns (uint256)",
  "function processed(bytes32) view returns (bool)",
  "event Credited(bytes32 indexed appId, bytes32 indexed account, uint256 amount, bytes32 indexed transferId)",
]);

// ---------------------------------------------------------------------------
// Keystore (Web3 Secret Storage v3, as written by `cast wallet import`)
// ---------------------------------------------------------------------------

function askPassword(prompt) {
  return new Promise((resolve) => {
    if (!process.stdin.isTTY) {
      // Non-interactive (rehearsal): read one line from stdin.
      const rl = createInterface({ input: process.stdin });
      rl.once("line", (line) => {
        rl.close();
        resolve(line);
      });
      return;
    }
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    rl._writeToOutput = (s) => {
      if (s.includes(prompt)) process.stdout.write(prompt);
    };
    rl.question(prompt, (answer) => {
      rl.close();
      process.stdout.write("\n");
      resolve(answer);
    });
  });
}

function decryptKeystore(json, password) {
  const c = json.crypto ?? json.Crypto;
  const kp = c.kdfparams;
  const salt = Buffer.from(kp.salt, "hex");
  let dk;
  if (c.kdf === "scrypt") {
    dk = scryptSync(Buffer.from(password, "utf8"), salt, kp.dklen, {
      N: kp.n,
      r: kp.r,
      p: kp.p,
      maxmem: 256 * kp.n * kp.r + 1024 * 1024,
    });
  } else if (c.kdf === "pbkdf2") {
    dk = pbkdf2Sync(Buffer.from(password, "utf8"), salt, kp.c, kp.dklen, "sha256");
  } else {
    throw new Error(`unsupported keystore kdf: ${c.kdf}`);
  }
  const ciphertext = Buffer.from(c.ciphertext, "hex");
  const mac = keccak256(concat([toHex(dk.subarray(16, 32)), toHex(ciphertext)])).slice(2);
  if (mac !== c.mac.toLowerCase()) throw new Error("wrong keystore password");
  const decipher = createDecipheriv("aes-128-ctr", dk.subarray(0, 16), Buffer.from(c.cipherparams.iv, "hex"));
  const pk = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  return `0x${pk.toString("hex")}`;
}

async function loadAccount() {
  const path = process.env.PORTAGE_KEYSTORE ?? join(homedir(), ".foundry", "keystores", "deployer");
  if (!existsSync(path)) throw new Error(`keystore not found at ${path} (set PORTAGE_KEYSTORE)`);
  const json = JSON.parse(readFileSync(path, "utf8"));
  const password = await askPassword(`Keystore password (${path.split("/").pop()}): `);
  const account = privateKeyToAccount(decryptKeystore(json, password));
  console.log(`Signer: ${account.address}`);
  return account;
}

// ---------------------------------------------------------------------------
// Deployment (from the forge broadcast file of the mainnet Deploy run)
// ---------------------------------------------------------------------------

function loadDeployment() {
  const path = process.env.PORTAGE_DEPLOYMENT ?? join(repoRoot, "broadcast", "Deploy.s.sol", String(ARC_CHAIN_ID), "run-latest.json");
  if (!existsSync(path)) throw new Error(`deployment file not found: ${path} — run the Deploy script first`);
  const run = JSON.parse(readFileSync(path, "utf8"));
  const out = {};
  for (const tx of run.transactions ?? []) {
    if (tx.transactionType === "CREATE" && tx.contractName && tx.contractAddress) {
      out[tx.contractName] = getAddress(tx.contractAddress);
    }
  }
  for (const k of ["AppRegistry", "Ledger", "PayoutEngine", "PortageRouter", "PortageMintForwarder"]) {
    if (!out[k]) throw new Error(`${k} missing from ${path}`);
  }
  return {
    registry: out.AppRegistry,
    ledger: out.Ledger,
    engine: out.PayoutEngine,
    router: out.PortageRouter,
    forwarder: out.PortageMintForwarder,
  };
}

async function checkDeployment(arc, d, appId) {
  const chainId = await arc.getChainId();
  if (chainId !== ARC_CHAIN_ID) throw new Error(`Arc RPC chain id is ${chainId}, expected ${ARC_CHAIN_ID}`);
  const [fwdRouter, fwdMinter, routerFwd, creditor, registered] = await Promise.all([
    arc.readContract({ address: d.forwarder, abi: portageAbi, functionName: "router" }),
    arc.readContract({ address: d.forwarder, abi: portageAbi, functionName: "gatewayMinter" }),
    arc.readContract({ address: d.router, abi: portageAbi, functionName: "forwarder" }),
    arc.readContract({ address: d.ledger, abi: portageAbi, functionName: "creditor" }),
    arc.readContract({ address: d.registry, abi: portageAbi, functionName: "isRegistered", args: [appId] }),
  ]);
  const problems = [];
  if (getAddress(fwdRouter) !== d.router) problems.push("forwarder.router != router");
  if (getAddress(fwdMinter) !== getAddress(GATEWAY_MINTER)) problems.push(`forwarder.gatewayMinter is ${fwdMinter}, not the mainnet minter`);
  if (getAddress(routerFwd) !== d.forwarder) problems.push("router.forwarder != forwarder");
  if (getAddress(creditor) !== d.router) problems.push("ledger.creditor != router");
  if (!registered) problems.push(`app "${APP_NAME}" is not registered`);
  if (problems.length) throw new Error(`deployment check failed:\n - ${problems.join("\n - ")}`);
  console.log("Deployment check: OK (wiring, mainnet minter, app registered)");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const b32 = (a) => pad(a.toLowerCase(), { size: 32 });
const usdc = (x) => formatUnits(x, 6);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function gatewayAvailable(api, depositor) {
  const res = await api.getBalances("USDC", [{ domain: BASE_DOMAIN, depositor }]);
  const e = res.balances.find((b) => b.domain === BASE_DOMAIN);
  return e ? parseUnits(e.balance, 6) : 0n;
}

/** Fields of a single Gateway Attestation at the offsets used by AttestationDecoder.sol. */
function decodeAttestation(att) {
  const bytes = Buffer.from(att.slice(2), "hex");
  const word = (off) => `0x${bytes.subarray(off, off + 32).toString("hex")}`;
  const specLen = bytes.readUInt32BE(36);
  return {
    magic: `0x${bytes.subarray(0, 4).toString("hex")}`,
    specHash: keccak256(`0x${bytes.subarray(40, 40 + specLen).toString("hex")}`),
    depositor: getAddress(`0x${word(184).slice(26)}`),
    recipient: getAddress(`0x${word(216).slice(26)}`),
    caller: getAddress(`0x${word(280).slice(26)}`),
    value: BigInt(word(312)),
  };
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

async function status() {
  const arc = createPublicClient({ chain: arcChain, transport: http(ARC_RPC) });
  const baseClient = createPublicClient({ chain: base, transport: http(BASE_RPC) });
  const api = new GatewayApi(GATEWAY_API);
  const account = await loadAccount();
  const me = account.address;
  const [arcGas, baseUsdc, gw] = await Promise.all([
    arc.getBalance({ address: me }),
    baseClient.readContract({ address: BASE_USDC, abi: erc20Abi, functionName: "balanceOf", args: [me] }),
    gatewayAvailable(api, me),
  ]);
  console.log(`Arc USDC (gas):          ${formatUnits(arcGas, 18)}`);
  console.log(`Base USDC (wallet):      ${usdc(baseUsdc)}`);
  console.log(`Gateway available (Base): ${usdc(gw)}`);
  if (existsSync(process.env.PORTAGE_DEPLOYMENT ?? join(repoRoot, "broadcast", "Deploy.s.sol", String(ARC_CHAIN_ID), "run-latest.json"))) {
    const d = loadDeployment();
    const appId = appIdFromName(APP_NAME);
    const total = await arc.readContract({ address: d.ledger, abi: portageAbi, functionName: "appBalance", args: [appId] });
    console.log(`Portage ledger "${APP_NAME}": ${usdc(total)} USDC  (${EXPLORER}/address/${d.ledger})`);
  }
}

async function consolidate(amountArg) {
  const amountUsdc = Number(amountArg ?? "1");
  if (!(amountUsdc > 0) || amountUsdc > MAX_AMOUNT_USDC) throw new Error(`amount must be in (0, ${MAX_AMOUNT_USDC}] USDC`);
  const amount = parseUnits(String(amountUsdc), 6);
  // Base gas fee $0.01 + 0.005% transfer fee (developers.circle.com/gateway/references/fees), with buffer.
  const maxFee = 50_000n; // 0.05 USDC

  const d = loadDeployment();
  const arc = createPublicClient({ chain: arcChain, transport: http(ARC_RPC) });
  const appId = appIdFromName(APP_NAME);
  await checkDeployment(arc, d, appId);

  const account = await loadAccount();
  const me = account.address;
  const api = new GatewayApi(GATEWAY_API);

  // 1. Wait until Circle has finalized enough of the Base deposit.
  const need = amount + maxFee;
  for (let i = 0; ; i++) {
    const avail = await gatewayAvailable(api, me);
    if (avail >= need) {
      console.log(`Gateway available on Base: ${usdc(avail)} USDC (need ${usdc(need)})`);
      break;
    }
    if (i === 0) console.log(`Waiting for the Base deposit to finalize in Gateway (have ${usdc(avail)}, need ${usdc(need)})...`);
    if (i > 0 && i % 6 === 0) console.log(`  still waiting: ${usdc(avail)} / ${usdc(need)} USDC (${i * 10}s)`);
    if (i > 360) throw new Error("Gateway balance did not finalize within 60 minutes; run again later");
    await sleep(10_000);
  }

  // 2. Burn intent: Base -> Arc, recipient = router, caller = forwarder, empty hookData.
  const salt = keccak256(toHex(`portage-pilot-${me}-${Date.now()}-${Math.random()}`));
  const spec = {
    version: 1,
    sourceDomain: BASE_DOMAIN,
    destinationDomain: ARC_DOMAIN,
    sourceContract: b32(GATEWAY_WALLET),
    destinationContract: b32(GATEWAY_MINTER),
    sourceToken: b32(BASE_USDC),
    destinationToken: b32(ARC_USDC),
    sourceDepositor: b32(me),
    destinationRecipient: b32(d.router),
    sourceSigner: b32(me),
    destinationCaller: b32(d.forwarder),
    value: amount,
    salt,
    hookData: "0x",
  };
  const message = { maxBlockHeight: maxUint256, maxFee, spec };
  const intentSig = await account.signTypedData({
    domain: GATEWAY_EIP712_DOMAIN,
    types: BURN_INTENT_TYPES,
    primaryType: "BurnIntent",
    message,
  });
  const specHash = transferSpecHash(spec);
  console.log(`Burn intent signed. specHash ${specHash}`);

  // 3. Attestation from Circle.
  const res = await api.submitTransfer(message, intentSig);
  const att = decodeAttestation(res.attestation);
  const problems = [];
  if (att.magic !== "0xff6fb334") problems.push(`unexpected attestation magic ${att.magic}`);
  if (att.specHash !== specHash) problems.push("attestation specHash differs from the signed spec");
  if (att.recipient !== d.router) problems.push("attestation recipient is not the router");
  if (att.caller !== d.forwarder) problems.push("attestation caller is not the forwarder");
  if (att.depositor !== getAddress(me)) problems.push("attestation depositor is not the signer");
  if (att.value !== amount) problems.push(`attestation value ${att.value} != ${amount}`);
  if (problems.length) throw new Error(`attestation check failed:\n - ${problems.join("\n - ")}`);
  console.log(`Attestation received (transferId ${res.transferId ?? "n/a"}) and checked.`);

  // 4. Meta binding: credit `APP_NAME`, sub-account "micrograms-pilot".
  const meta = {
    schema: 1,
    appId,
    account: accountIdFromName("micrograms-pilot"),
    action: PayoutAction.Credit,
    referenceId: keccak256(toHex(`pilot-${specHash}`)),
    payer: b32(me),
  };
  const [schema, mAppId, mAccount, action, referenceId, payer] = payoutMetaTuple(meta);
  const metaSig = await account.signTypedData({
    domain: { name: "Portage", version: "1", chainId: ARC_CHAIN_ID, verifyingContract: d.forwarder },
    types: META_BINDING_TYPES,
    primaryType: "PayoutMetaBinding",
    message: { specHash, schema, appId: mAppId, account: mAccount, action, referenceId, payer },
  });

  writeFileSync(
    STATE_FILE,
    JSON.stringify({ deployment: d, attestation: res.attestation, signature: res.signature, meta, metaSig, specHash, amount: amount.toString() }, null, 2),
  );
  console.log(`State saved to ${STATE_FILE} (no secrets; lets 'execute' retry the Arc step).`);

  await execute(account, arc);
}

async function execute(accountArg, arcArg) {
  if (!existsSync(STATE_FILE)) throw new Error("no saved state; run 'consolidate' first");
  const st = JSON.parse(readFileSync(STATE_FILE, "utf8"));
  const d = st.deployment;
  const arc = arcArg ?? createPublicClient({ chain: arcChain, transport: http(ARC_RPC) });
  const account = accountArg ?? (await loadAccount());
  const wallet = createWalletClient({ account, chain: arcChain, transport: http(ARC_RPC) });
  const [schema, appId, acct, action, referenceId, payer] = payoutMetaTuple(st.meta);
  const args = [st.attestation, st.signature, { schema, appId, account: acct, action, referenceId, payer }, st.metaSig];

  if (await arc.readContract({ address: d.router, abi: portageAbi, functionName: "processed", args: [st.specHash] })) {
    console.log(`Already executed: transfer ${st.specHash} has been handled by the router. Nothing to do.`);
    return;
  }
  const before = await arc.readContract({ address: d.ledger, abi: portageAbi, functionName: "balanceOf", args: [appId, acct] });
  const { request } = await arc.simulateContract({ account, address: d.forwarder, abi: mintForwarderAbi, functionName: "executeMintWithMeta", args });
  const hash = await wallet.writeContract(request);
  console.log(`executeMintWithMeta sent: ${EXPLORER}/tx/${hash}`);
  const receipt = await arc.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`Arc tx reverted: ${EXPLORER}/tx/${hash}`);

  let credited = null;
  for (const log of receipt.logs) {
    if (getAddress(log.address) !== getAddress(d.ledger)) continue;
    try {
      const ev = decodeEventLog({ abi: portageAbi, data: log.data, topics: log.topics });
      if (ev.eventName === "Credited") credited = { ...ev.args, logIndex: log.logIndex };
    } catch {}
  }
  const after = await arc.readContract({ address: d.ledger, abi: portageAbi, functionName: "balanceOf", args: [appId, acct] });
  console.log(`Block ${receipt.blockNumber}, status success.`);
  if (credited) console.log(`Ledger.Credited at log ${credited.logIndex}: ${usdc(credited.amount)} USDC, transferId ${credited.transferId}`);
  else console.log("WARNING: no Ledger.Credited log in the receipt (deposit may have been quarantined)");
  console.log(`Ledger balance ${APP_NAME}/micrograms-pilot: ${usdc(before)} -> ${usdc(after)} USDC`);
  console.log(`\nShare these:\n  tx:     ${EXPLORER}/tx/${hash}\n  ledger: ${EXPLORER}/address/${d.ledger}\n  router: ${EXPLORER}/address/${d.router}`);
}

const [cmd, arg] = process.argv.slice(2);
const commands = { status: () => status(), consolidate: () => consolidate(arg), execute: () => execute() };
if (!commands[cmd]) {
  console.log("usage: node sdk/scripts/mainnet-pilot.mjs <status|consolidate [amountUSDC]|execute>");
  process.exit(1);
}
commands[cmd]().catch((e) => {
  console.error(`\nERROR: ${e.shortMessage ?? e.message}`);
  process.exit(1);
});
