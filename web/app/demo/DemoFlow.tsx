"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  createPublicClient,
  createWalletClient,
  custom,
  erc20Abi,
  formatUnits,
  http,
  keccak256,
  parseAbi,
  parseUnits,
  toHex,
  type Address,
  type EIP1193Provider,
  type Hex,
} from "viem";
import { baseSepolia } from "viem/chains";
import {
  GatewayApi,
  PayoutAction,
  PortageClient,
  accountIdFromName,
  addressToBytes32,
  appIdFromName,
} from "@erhnysr/portage-sdk";
import s from "./demo.module.css";
import {
  APP_REGISTRY,
  EXPLORER_API,
  FAUCET_URL,
  SOURCES,
  SOURCE_ORDER,
  arcTestnet,
  type SourceKey,
} from "./chains";

declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}

type StepState = "todo" | "active" | "done" | "skipped" | "error";
type Phase =
  | "disconnected"
  | "ready"
  | "depositing"
  | "finalizing"
  | "signing"
  | "attesting"
  | "minting"
  | "indexing"
  | "done";

type Balances = {
  gateway: Record<SourceKey, bigint>;
  baseUsdc: bigint;
  baseEth: bigint;
  arcGas: bigint; // 18-decimal native
};

type Pending = { depositTx: Hex; need: string; at: number };

const USDC_BASE = "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as const;
const MIN_AMOUNT = parseUnits("0.1", 6);
const MAX_AMOUNT = parseUnits("5", 6);
const registryAbi = parseAbi(["function isRegistered(bytes32 appId) view returns (bool)"]);

const arcPublic = createPublicClient({ chain: arcTestnet, transport: http() });
const basePublic = createPublicClient({ chain: baseSepolia, transport: http() });
const gatewayApi = new GatewayApi();
const portage = new PortageClient({ arcPublicClient: arcPublic, gatewayApi });

// Gateway caps the fee at maxFee and deducts it from the unified balance, so the balance
// needs value + maxFee of headroom. Mirrors the SDK default (sdk/src/burnIntent.ts).
const maxFeeFor = (amount: bigint) => (amount > 10_000_000n ? 2_010_000n : amount / 10n);
const fmt = (v: bigint, d = 6, digits = 2) => {
  const n = Number(formatUnits(v, d));
  return n.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: Math.max(digits, 2) });
};
const shortAddr = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const pendingKey = (a: string) => `portage-demo:pending:${a.toLowerCase()}`;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
// Storage can be unavailable (private windows, blocked site data); the flow must still work.
const store = {
  get(k: string): string | null {
    try {
      return window.localStorage.getItem(k);
    } catch {
      return null;
    }
  },
  set(k: string, v: string) {
    try {
      window.localStorage.setItem(k, v);
    } catch {}
  },
  del(k: string) {
    try {
      window.localStorage.removeItem(k);
    } catch {}
  },
};

function errText(e: unknown): string {
  const any = e as { shortMessage?: string; message?: string; code?: number };
  if (any?.code === 4001 || /User rejected|denied/i.test(any?.message ?? "")) return "You rejected the request in your wallet.";
  return any?.shortMessage ?? any?.message ?? String(e);
}

export default function DemoFlow() {
  const [hasWallet, setHasWallet] = useState<boolean | null>(null);
  const [address, setAddress] = useState<Address | null>(null);
  const [phase, setPhase] = useState<Phase>("disconnected");
  const [balances, setBalances] = useState<Balances | null>(null);
  const [amountStr, setAmountStr] = useState("0.50");
  const [source, setSource] = useState<SourceKey>("baseSepolia");
  const [app, setApp] = useState<{ name: string; id: Hex } | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [mintTx, setMintTx] = useState<Hex | null>(null);
  const [indexed, setIndexed] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const busy = useRef(false);

  useEffect(() => setHasWallet(typeof window !== "undefined" && !!window.ethereum), []);

  // Which app to credit: portage-demo once registered on-chain, else coliseum (always registered).
  useEffect(() => {
    (async () => {
      const demoId = appIdFromName("portage-demo");
      try {
        const ok = await arcPublic.readContract({ address: APP_REGISTRY, abi: registryAbi, functionName: "isRegistered", args: [demoId] });
        setApp(ok ? { name: "portage-demo", id: demoId } : { name: "coliseum", id: appIdFromName("coliseum") });
      } catch {
        setApp({ name: "coliseum", id: appIdFromName("coliseum") });
      }
    })();
  }, []);

  const amount = useMemo(() => {
    try {
      const v = parseUnits(amountStr || "0", 6);
      return v;
    } catch {
      return 0n;
    }
  }, [amountStr]);
  const amountOk = amount >= MIN_AMOUNT && amount <= MAX_AMOUNT;
  const need = amount + maxFeeFor(amount);

  const refresh = useCallback(async (who: Address) => {
    const [gw, baseUsdc, baseEth, arcGas] = await Promise.all([
      gatewayApi.getBalances(
        "USDC",
        SOURCE_ORDER.map((k) => ({ domain: SOURCES[k].domain, depositor: who })),
      ),
      basePublic.readContract({ address: USDC_BASE, abi: erc20Abi, functionName: "balanceOf", args: [who] }),
      basePublic.getBalance({ address: who }),
      arcPublic.getBalance({ address: who }),
    ]);
    const gateway = Object.fromEntries(SOURCE_ORDER.map((k) => [k, 0n])) as Record<SourceKey, bigint>;
    for (const b of gw.balances) {
      const key = SOURCE_ORDER.find((k) => SOURCES[k].domain === b.domain);
      if (key) gateway[key] = parseUnits(b.balance, 6);
    }
    const next = { gateway, baseUsdc, baseEth, arcGas };
    setBalances(next);
    return next;
  }, []);

  // Light polling while the user is looking at balances or waiting on finality.
  useEffect(() => {
    if (!address || !(phase === "ready" || phase === "finalizing")) return;
    const id = setInterval(() => {
      refresh(address).catch(() => {});
      setNow(Date.now());
    }, phase === "finalizing" ? 8000 : 20000);
    return () => clearInterval(id);
  }, [address, phase, refresh]);

  // Finality watcher: once Gateway credits the deposit, the flow unlocks by itself.
  useEffect(() => {
    if (phase !== "finalizing" || !pending || !balances) return;
    if (balances.gateway.baseSepolia >= BigInt(pending.need)) {
      store.del(pendingKey(address!));
      setPending(null);
      setSource("baseSepolia");
      setNote("Circle Gateway finalized your deposit. You can clear it on Arc now.");
      setPhase("ready");
    }
  }, [phase, pending, balances, address]);

  useEffect(() => {
    if (phase !== "finalizing") return;
    const id = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(id);
  }, [phase]);

  // Pick a source that can already cover the transfer, preferring the verified route.
  useEffect(() => {
    if (!balances || phase !== "ready") return;
    if (balances.gateway[source] >= need) return;
    const covered = SOURCE_ORDER.find((k) => balances.gateway[k] >= need);
    if (covered) setSource(covered);
  }, [balances, need, phase, source]);

  const wallet = useCallback((chain: typeof arcTestnet | typeof baseSepolia) => {
    return createWalletClient({ account: address!, chain, transport: custom(window.ethereum!) });
  }, [address]);

  async function ensureChain(chain: typeof arcTestnet | typeof baseSepolia) {
    const wc = createWalletClient({ chain, transport: custom(window.ethereum!) });
    const current = await wc.getChainId();
    if (current === chain.id) return;
    try {
      await wc.switchChain({ id: chain.id });
    } catch (e) {
      const code = (e as { code?: number; cause?: { code?: number } })?.code ?? (e as { cause?: { code?: number } })?.cause?.code;
      if (code === 4902 || /Unrecognized chain|not been added/i.test(String((e as Error)?.message))) {
        await wc.addChain({ chain });
        await wc.switchChain({ id: chain.id });
      } else {
        throw e;
      }
    }
  }

  async function connect() {
    setError(null);
    try {
      const wc = createWalletClient({ transport: custom(window.ethereum!) });
      const [who] = await wc.requestAddresses();
      setAddress(who);
      await refresh(who);
      const raw = store.get(pendingKey(who));
      if (raw) {
        const p = JSON.parse(raw) as Pending;
        setPending(p);
        setPhase("finalizing");
      } else {
        setPhase("ready");
      }
    } catch (e) {
      setError(errText(e));
    }
  }

  async function deposit() {
    if (busy.current || !address) return;
    busy.current = true;
    setError(null);
    setNote(null);
    setPhase("depositing");
    try {
      await ensureChain(baseSepolia);
      const { depositTx } = await portage.deposit(wallet(baseSepolia), {
        chain: "baseSepolia",
        amount: need,
        // Base Sepolia's OP-stack client type (deposit tx formatters) is wider than the SDK's
        // generic PublicClient parameter; at runtime it is the same viem client.
        sourcePublicClient: basePublic as unknown as Parameters<typeof portage.deposit>[1]["sourcePublicClient"],
      });
      await basePublic.waitForTransactionReceipt({ hash: depositTx });
      const p: Pending = { depositTx, need: need.toString(), at: Date.now() };
      store.set(pendingKey(address), JSON.stringify(p));
      setPending(p);
      await refresh(address);
      setPhase("finalizing");
    } catch (e) {
      setError(errText(e));
      setPhase("ready");
    } finally {
      busy.current = false;
    }
  }

  async function consolidate() {
    if (busy.current || !address || !app) return;
    busy.current = true;
    setError(null);
    setNote(null);
    setMintTx(null);
    setIndexed(false);
    try {
      setPhase("signing");
      // Everything from here happens on Arc: the PayoutMeta binding is EIP-712 with Arc's chainId,
      // which wallets require to match the active chain. The Gateway burn intent has no chainId.
      await ensureChain(arcTestnet);
      const arcWallet = wallet(arcTestnet);
      const intent = portage.buildConsolidationIntent({
        sourceChain: source,
        amount,
        depositor: address,
        maxFee: maxFeeFor(amount),
      });
      const burnSig = await arcWallet.signTypedData({ account: address, ...intent.typedData });
      const specHash = portage.specHash(intent);
      const meta = {
        appId: app.id,
        account: accountIdFromName(`demo:${address.toLowerCase()}`),
        action: PayoutAction.Topup,
        referenceId: keccak256(toHex(`portage-demo:${address.toLowerCase()}:${Date.now()}`)),
        payer: addressToBytes32(address),
      };
      const metaSig = await arcWallet.signTypedData({ account: address, ...portage.buildMetaBinding(specHash, meta) });

      setPhase("attesting");
      let transfer: { attestation: Hex; signature: Hex; transferId: string } | null = null;
      let lastErr = "";
      for (let i = 0; i < 20 && !transfer; i++) {
        try {
          const t = await portage.submitConsolidation(intent, burnSig);
          if (t.attestation && t.attestation !== "0x") transfer = t;
          else if (t.transferId) {
            for (let j = 0; j < 20; j++) {
              const rec = (await gatewayApi.getTransfer(t.transferId)) as { attestation?: Hex; signature?: Hex };
              if (rec.attestation && rec.signature) {
                transfer = { attestation: rec.attestation, signature: rec.signature, transferId: t.transferId };
                break;
              }
              await sleep(4000);
            }
          }
        } catch (e) {
          lastErr = errText(e);
          await sleep(5000);
        }
      }
      if (!transfer) throw new Error(`Circle Gateway did not return an attestation. ${lastErr}`);

      setPhase("minting");
      const tx = await portage.executeMintWithMeta(arcWallet, {
        attestation: transfer.attestation,
        signature: transfer.signature,
        meta,
        metaSig,
      });
      setMintTx(tx);
      const receipt = await arcPublic.waitForTransactionReceipt({ hash: tx });
      if (receipt.status !== "success") throw new Error("The Arc transaction reverted.");

      setPhase("indexing");
      for (let i = 0; i < 30; i++) {
        const r = await fetch(`${EXPLORER_API}/transactions/${tx}`).catch(() => null);
        if (r?.ok) {
          setIndexed(true);
          break;
        }
        await sleep(2000);
      }
      await refresh(address).catch(() => {});
      setPhase("done");
    } catch (e) {
      setError(errText(e));
      setPhase("ready");
    } finally {
      busy.current = false;
    }
  }

  // ---------------------------------------------------------------- derived UI state
  const covered = balances ? balances.gateway[source] >= need : false;
  const anyCovered = balances ? SOURCE_ORDER.some((k) => balances.gateway[k] >= need) : false;
  const arcGasOk = balances ? balances.arcGas > 0n : false;
  const canDeposit = balances ? balances.baseUsdc >= need && balances.baseEth > 0n : false;
  const working = ["depositing", "signing", "attesting", "minting", "indexing"].includes(phase);

  const steps: { title: string; body: string; state: StepState }[] = [
    {
      title: "Connect a wallet",
      body: address ? `Connected as ${shortAddr(address)}.` : "Any browser wallet. Nothing is custodied — every action is a signature you approve.",
      state: address ? "done" : "active",
    },
    {
      title: "Fund your Gateway balance",
      body:
        phase === "depositing"
          ? "Approving and depositing USDC into Circle Gateway on Base Sepolia…"
          : phase === "finalizing"
            ? "Deposit confirmed on-chain. Circle Gateway credits it once Base Sepolia finalizes the block — minutes, not seconds. You can close this tab; your balance lives with Circle, not with this page."
            : anyCovered && address
              ? "You already hold a Gateway balance — deposit once, spend from any chain."
              : "Deposit USDC into Circle Gateway on a source chain. One-time; after finality it's spendable anywhere.",
      state: !address ? "todo" : phase === "depositing" || phase === "finalizing" ? "active" : anyCovered || ["signing", "attesting", "minting", "indexing", "done"].includes(phase) ? "done" : "active",
    },
    {
      title: "Sign the transfer",
      body: "Two signatures: Circle's burn intent (moves the value), and Portage's PayoutMeta binding (says whose ledger to credit). No transaction yet.",
      state: phase === "signing" ? "active" : ["attesting", "minting", "indexing", "done"].includes(phase) ? "done" : "todo",
    },
    {
      title: "Circle attests",
      body: "Circle Gateway checks your balance and returns a signed attestation for Arc.",
      state: phase === "attesting" ? "active" : ["minting", "indexing", "done"].includes(phase) ? "done" : "todo",
    },
    {
      title: "Clear on Arc",
      body: "One Arc transaction mints the USDC to the Portage Router and credits the ledger atomically.",
      state: phase === "minting" || phase === "indexing" ? "active" : phase === "done" ? "done" : "todo",
    },
  ];

  const elapsed = pending ? Math.max(0, Math.floor((now - pending.at) / 1000)) : 0;

  return (
    <div className={s.grid}>
      {/* ---------------------------------------------------------------- steps */}
      <ol className={s.steps}>
        {steps.map((st, i) => (
          <li key={st.title} className={`${s.step} ${s[st.state]}`}>
            <span className={s.stepIdx} aria-hidden="true">
              {st.state === "done" ? "✓" : i + 1}
            </span>
            <div>
              <div className={s.stepTitle}>
                {st.title}
                {st.state === "active" && working ? <span className={s.spinner} aria-label="in progress" /> : null}
              </div>
              <p className={s.stepBody}>{st.body}</p>
              {i === 1 && phase === "finalizing" ? (
                <p className={s.timer}>
                  Waiting for finality · {Math.floor(elapsed / 60)}m {String(elapsed % 60).padStart(2, "0")}s
                  {pending ? (
                    <>
                      {" · "}
                      <a className={s.link} href={`https://sepolia.basescan.org/tx/${pending.depositTx}`} target="_blank" rel="noopener noreferrer">
                        deposit tx ↗
                      </a>
                    </>
                  ) : null}
                </p>
              ) : null}
            </div>
          </li>
        ))}
      </ol>

      {/* ---------------------------------------------------------------- console */}
      <div className={s.console}>
        {hasWallet === false ? (
          <div className={s.block}>
            <h3 className={s.h3}>No browser wallet found</h3>
            <p className={s.p}>
              Install MetaMask, Rabby or Coinbase Wallet to run the demo. Or skip the wallet and{" "}
              <a className={s.link} href="/explorer">
                inspect real shipments in the explorer
              </a>
              .
            </p>
          </div>
        ) : !address ? (
          <div className={s.block}>
            <h3 className={s.h3}>Move testnet USDC into a Portage ledger on Arc</h3>
            <p className={s.p}>
              You&apos;ll need testnet USDC on Base Sepolia (to deposit) and a little USDC on Arc Testnet (Arc&apos;s gas
              token). Both come from{" "}
              <a className={s.link} href={FAUCET_URL} target="_blank" rel="noopener noreferrer">
                Circle&apos;s faucet ↗
              </a>
              .
            </p>
            <button className={s.primary} onClick={connect} disabled={hasWallet === null}>
              Connect wallet
            </button>
          </div>
        ) : (
          <>
            <div className={s.walletRow}>
              <span className={s.walletDot} aria-hidden="true" />
              <span className={s.mono}>{shortAddr(address)}</span>
              <button className={s.textBtn} onClick={() => refresh(address).catch(() => {})} disabled={working}>
                Refresh
              </button>
            </div>

            <div className={s.balances}>
              <div className={s.balHead}>Circle Gateway balance</div>
              {SOURCE_ORDER.map((k) => (
                <div key={k} className={s.balRow}>
                  <span>
                    {SOURCES[k].label}
                    {SOURCES[k].verified ? <span className={s.verified}>tested</span> : null}
                  </span>
                  <span className={s.mono}>{balances ? fmt(balances.gateway[k]) : "…"} USDC</span>
                </div>
              ))}
              <div className={s.balHead}>Wallet</div>
              <div className={s.balRow}>
                <span>Base Sepolia USDC</span>
                <span className={s.mono}>{balances ? fmt(balances.baseUsdc) : "…"}</span>
              </div>
              <div className={s.balRow}>
                <span>Arc gas (USDC)</span>
                <span className={`${s.mono} ${balances && !arcGasOk ? s.warn : ""}`}>
                  {balances ? fmt(balances.arcGas, 18, 3) : "…"}
                </span>
              </div>
            </div>

            {phase === "done" && mintTx ? (
              <div className={s.success}>
                <div className={s.successTitle}>
                  {fmt(amount)} USDC cleared to {app?.name}
                </div>
                <p className={s.p}>
                  One Arc transaction minted it to the Portage Router and credited your demo account. Every claim is
                  re-checked from calldata on the receipt page.
                </p>
                <div className={s.actions}>
                  {indexed ? (
                    <a className={s.primary} href={`/explorer/${mintTx}`}>
                      Open verified receipt →
                    </a>
                  ) : (
                    <a className={s.primary} href={`https://explorer.testnet.arc.io/tx/${mintTx}`} target="_blank" rel="noopener noreferrer">
                      View on Arc explorer ↗
                    </a>
                  )}
                  <button className={s.ghost} onClick={() => setPhase("ready")}>
                    Run again
                  </button>
                </div>
              </div>
            ) : (
              <div className={s.block}>
                <label className={s.label} htmlFor="amt">
                  Amount to clear
                </label>
                <div className={s.amountRow}>
                  <input
                    id="amt"
                    className={s.input}
                    inputMode="decimal"
                    value={amountStr}
                    onChange={(e) => setAmountStr(e.target.value.replace(/[^0-9.]/g, ""))}
                    disabled={working || phase === "finalizing"}
                  />
                  <span className={s.unit}>USDC</span>
                </div>
                <p className={s.hint}>
                  {amountOk
                    ? `Gateway fee ceiling ${fmt(maxFeeFor(amount))} USDC — needs ${fmt(need)} USDC of Gateway balance.`
                    : "Between 0.10 and 5.00 USDC."}
                </p>

                {anyCovered ? (
                  <>
                    <label className={s.label} htmlFor="src">
                      Spend from
                    </label>
                    <select id="src" className={s.input} value={source} onChange={(e) => setSource(e.target.value as SourceKey)} disabled={working}>
                      {SOURCE_ORDER.filter((k) => balances && balances.gateway[k] >= need).map((k) => (
                        <option key={k} value={k}>
                          {SOURCES[k].label} — {fmt(balances!.gateway[k])} USDC
                        </option>
                      ))}
                    </select>
                  </>
                ) : null}

                {phase === "finalizing" ? (
                  <button className={s.primary} disabled>
                    Waiting for Gateway finality…
                  </button>
                ) : covered ? (
                  <button className={s.primary} onClick={consolidate} disabled={!amountOk || working || !arcGasOk || !app}>
                    {working ? phaseLabel(phase) : `Clear ${fmt(amount)} USDC on Arc`}
                  </button>
                ) : (
                  <button className={s.primary} onClick={deposit} disabled={!amountOk || working || !canDeposit}>
                    {phase === "depositing" ? "Depositing…" : `Deposit ${fmt(need)} USDC from Base Sepolia`}
                  </button>
                )}

                {!arcGasOk && balances && covered ? (
                  <p className={s.warnNote}>
                    You need a little USDC on Arc Testnet to pay gas —{" "}
                    <a className={s.link} href={FAUCET_URL} target="_blank" rel="noopener noreferrer">
                      get some from the faucet ↗
                    </a>
                  </p>
                ) : null}
                {!covered && balances && !canDeposit && phase === "ready" ? (
                  <p className={s.warnNote}>
                    Deposit needs {fmt(need)} USDC and a little ETH on Base Sepolia —{" "}
                    <a className={s.link} href={FAUCET_URL} target="_blank" rel="noopener noreferrer">
                      Circle faucet ↗
                    </a>
                  </p>
                ) : null}
                {app ? (
                  <p className={s.hint}>
                    Credits the <span className={s.mono}>{app.name}</span> app on Arc, under an account derived from your address.
                  </p>
                ) : null}
              </div>
            )}

            {note ? <p className={s.okNote}>{note}</p> : null}
            {error ? (
              <p className={s.errNote} role="alert">
                {error}
              </p>
            ) : null}
            {mintTx && phase !== "done" ? (
              <p className={s.hint}>
                Arc tx{" "}
                <a className={s.link} href={`https://explorer.testnet.arc.io/tx/${mintTx}`} target="_blank" rel="noopener noreferrer">
                  {shortAddr(mintTx)} ↗
                </a>
              </p>
            ) : null}
          </>
        )}
      </div>
    </div>
  );
}

function phaseLabel(p: Phase): string {
  switch (p) {
    case "signing":
      return "Waiting for signatures…";
    case "attesting":
      return "Circle is attesting…";
    case "minting":
      return "Clearing on Arc…";
    case "indexing":
      return "Indexing receipt…";
    default:
      return "Working…";
  }
}
