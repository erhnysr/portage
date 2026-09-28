import type { Metadata } from "next";
import { notFound } from "next/navigation";
import styles from "../../page.module.css";
import x from "../explorer.module.css";
import { Logo, SiteNav } from "../../../components/SiteNav";
import { getShipmentDetail } from "../../../lib/shipmentDetail";
import {
  ARC_EXPLORER_ADDRESS,
  ARC_EXPLORER_TX,
  GATEWAY_DOMAINS,
  actionLabel,
  appName,
  domainName,
  formatUsdcFull,
  quarantineReasonLabel,
} from "../../../lib/portage";
import { formatGasUsdc, formatUtc, middle } from "../../../lib/format";

// Rendered per request; the underlying explorer reads are cached (only on success) in
// lib/shipmentDetail.ts, so a just-landed shipment is never pinned as "not found".
export const dynamic = "force-dynamic";

type Params = { tx: string };
const TX_RE = /^0x[0-9a-fA-F]{64}$/;

export async function generateMetadata({ params }: { params: Promise<Params> }): Promise<Metadata> {
  const { tx } = await params;
  return {
    title: `Shipment ${middle(tx)} — Portage Explorer`,
    description: "A Portage shipment on Arc Testnet, re-verified from raw calldata.",
  };
}

function addrLink(base: string | undefined, addr: string) {
  if (!base) return <span className={x.hash}>{middle(addr)}</span>;
  return (
    <a className={x.link} href={`${base}${addr}`} target="_blank" rel="noopener noreferrer">
      {middle(addr)} ↗
    </a>
  );
}

export default async function ShipmentPage({ params }: { params: Promise<Params> }) {
  const { tx } = await params;
  if (!TX_RE.test(tx)) notFound();

  const res = await getShipmentDetail(tx as `0x${string}`);
  if (!res.ok && res.reason !== "unavailable") notFound();

  return (
    <div className={styles.page}>
      <SiteNav active="explorer" />

      <section className={`${styles.section} ${x.head}`}>
        <div className={styles.sectionInner}>
          <a href="/explorer" className={x.back}>
            ← All shipments
          </a>

          {!res.ok ? (
            <div className={x.unavailable}>
              <h1 className={x.title}>Shipment temporarily unreadable.</h1>
              <p className={styles.sectionLede}>
                The Arc explorer index didn&apos;t answer. The transaction is still public — open it
                directly:{" "}
                <a className={x.link} href={`${ARC_EXPLORER_TX}${tx}`} target="_blank" rel="noopener noreferrer">
                  {middle(tx)} ↗
                </a>
              </p>
            </div>
          ) : (
            <Detail d={res.detail} />
          )}
        </div>
      </section>

      <footer className={styles.footer}>
        <div className={styles.footerBottom}>
          <a href="/" className={styles.brand} aria-label="Portage home">
            <Logo size={20} />
            <span className={styles.wordmarkSm}>Portage</span>
          </a>
          <span className={styles.builtOn}>Built on Arc</span>
        </div>
        <p className={styles.legal}>
          Arc™ is a trademark of Circle Internet Group, Inc. Portage is an independent project and
          is not affiliated with or endorsed by Circle. © 2026 Portage.
        </p>
      </footer>
    </div>
  );
}

function Detail({ d }: { d: import("../../../lib/shipmentDetail").ShipmentDetail }) {
  const a = d.attestation;
  const held = d.status === "held";
  const amount = formatUsdcFull(BigInt(d.credited?.amount ?? d.quarantined?.amount ?? "0"));
  const passed = d.checks.filter((c) => c.ok).length;
  const allPassed = passed === d.checks.length && d.txSucceeded;
  const src = GATEWAY_DOMAINS[a.sourceDomain];
  const dst = GATEWAY_DOMAINS[a.destinationDomain];

  return (
    <>
      <div className={x.titleRow}>
        <span className={styles.eyebrow}>
          <span className={styles.eyebrowNum}>SHIPMENT</span> / {middle(d.txHash)}
        </span>
        <span className={`${x.pill} ${held ? x.pillHeld : x.pillCleared}`}>{held ? "HELD" : "CLEARED"}</span>
      </div>
      <h1 className={x.title}>
        {amount} USDC {held ? "held in quarantine" : <>cleared to {appName(d.credited!.appId)}</>}
      </h1>
      <p className={x.meta}>
        {formatUtc(d.timestamp)} · Arc block #{Number(d.blockNumber).toLocaleString("en-US")} ·{" "}
        <a className={x.link} href={`${ARC_EXPLORER_TX}${d.txHash}`} target="_blank" rel="noopener noreferrer">
          view on Arc explorer ↗
        </a>
      </p>

      {/* ---------- route: source chain → Circle Gateway → Arc ---------- */}
      <ol className={x.route} aria-label="Shipment route">
        <li className={`${x.station} ${x.stPurple}`}>
          <span className={x.stationChain}>{domainName(a.sourceDomain)}</span>
          <span className={x.stationTitle}>Deposited into Circle Gateway</span>
          <dl className={x.kv}>
            <dt>Depositor</dt>
            <dd>{addrLink(src?.explorerAddress, a.sourceDepositor)}</dd>
            <dt>Gateway wallet</dt>
            <dd>{addrLink(src?.explorerAddress, a.sourceContract)}</dd>
          </dl>
        </li>
        <li className={`${x.station} ${x.stBlue}`}>
          <span className={x.stationChain}>Circle Gateway</span>
          <span className={x.stationTitle}>Transfer attested</span>
          <dl className={x.kv}>
            <dt>Value</dt>
            <dd>{formatUsdcFull(BigInt(a.value))} USDC</dd>
            <dt>Spec hash</dt>
            <dd className={x.hash}>{middle(a.specHash)}</dd>
            <dt>Valid through</dt>
            <dd>Arc block #{Number(a.maxBlockHeight).toLocaleString("en-US")}</dd>
          </dl>
        </li>
        <li className={`${x.station} ${x.stCyan}`}>
          <span className={x.stationChain}>{domainName(a.destinationDomain)}</span>
          <span className={x.stationTitle}>Minted &amp; {held ? "quarantined" : "credited"} in one tx</span>
          <dl className={x.kv}>
            <dt>Call</dt>
            <dd className={x.hash}>{d.method}</dd>
            <dt>Submitted by</dt>
            <dd>{addrLink(dst?.explorerAddress ?? ARC_EXPLORER_ADDRESS, d.submitter)}</dd>
            <dt>Gas paid</dt>
            <dd>{formatGasUsdc(d.feeWei)} USDC</dd>
          </dl>
        </li>
      </ol>

      <div className={x.grid2}>
        {/* ---------- independent verification ---------- */}
        <div className={x.panel}>
          <div className={x.panelHead}>
            <span className={styles.manifestTitle}>Verified from calldata</span>
            <span className={`${x.score} ${allPassed ? x.scoreOk : x.scoreBad}`}>
              {passed}/{d.checks.length} checks
            </span>
          </div>
          <p className={x.panelLede}>
            Recomputed on this server from the transaction&apos;s raw input — not read from a database,
            and not from the explorer&apos;s own decoding.
          </p>
          <ul className={x.checks}>
            {!d.txSucceeded ? (
              <li className={x.check}>
                <span className={`${x.mark} ${x.markBad}`} aria-label="failed">
                  ✕
                </span>
                <span>
                  <strong>Transaction reverted</strong>
                  <span className={x.checkDetail}>The Arc transaction did not succeed.</span>
                </span>
              </li>
            ) : null}
            {d.checks.map((c) => (
              <li key={c.label} className={x.check}>
                <span className={`${x.mark} ${c.ok ? x.markOk : x.markBad}`} aria-label={c.ok ? "passed" : "failed"}>
                  {c.ok ? "✓" : "✕"}
                </span>
                <span>
                  <strong>{c.label}</strong>
                  <span className={x.checkDetail}>{c.detail}</span>
                </span>
              </li>
            ))}
          </ul>
        </div>

        {/* ---------- ledger entry ---------- */}
        <div className={x.panel}>
          <div className={x.panelHead}>
            <span className={styles.manifestTitle}>{held ? "Quarantine entry" : "Ledger entry"}</span>
          </div>
          <dl className={`${x.kv} ${x.kvWide}`}>
            {d.credited ? (
              <>
                <dt>App</dt>
                <dd>
                  {appName(d.credited.appId)}
                  <span className={x.full}>{d.credited.appId}</span>
                </dd>
                <dt>Account</dt>
                <dd className={x.full}>{d.credited.account}</dd>
                <dt>Purpose</dt>
                <dd>{actionLabel(d.credited.action)}</dd>
                <dt>Reference</dt>
                <dd className={x.full}>{d.credited.referenceId}</dd>
              </>
            ) : d.quarantined ? (
              <>
                <dt>Reason</dt>
                <dd>{quarantineReasonLabel(d.quarantined.reason)}</dd>
              </>
            ) : null}
            {d.meta ? (
              <>
                <dt>Payer</dt>
                <dd className={x.full}>{d.meta.payer}</dd>
              </>
            ) : null}
            <dt>Spec hash</dt>
            <dd className={x.full}>{a.specHash}</dd>
            <dt>Transaction</dt>
            <dd className={x.full}>{d.txHash}</dd>
          </dl>
        </div>
      </div>
    </>
  );
}
