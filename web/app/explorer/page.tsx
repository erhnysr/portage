import type { Metadata } from "next";
import styles from "../page.module.css";
import x from "./explorer.module.css";
import { Logo, SiteNav } from "../../components/SiteNav";
import { getShipments } from "../../lib/shipments";
import {
  ARC_EXPLORER_ADDRESS,
  ROUTER_ADDRESS,
  actionLabel,
  appName,
  formatUsdcFull,
  quarantineReasonLabel,
} from "../../lib/portage";
import { formatUtc, middle } from "../../lib/format";

// Same cadence as the landing manifest: at most one indexer read per minute.
export const revalidate = 60;

export const metadata: Metadata = {
  title: "Explorer — Portage",
  description:
    "Every Portage shipment on Arc Testnet, read from the Router and re-verified from raw calldata.",
};

export default async function ExplorerPage() {
  const result = await getShipments();
  const rows = result.ok ? result.shipments : [];
  const cleared = rows.filter((r) => r.status === "cleared");
  const clearedTotal = cleared.reduce((sum, r) => sum + BigInt(r.amount), 0n);
  const apps = new Set(cleared.map((r) => r.appId).filter(Boolean));
  const latest = cleared[0]?.timestamp ?? null;
  const routerUrl = `${ARC_EXPLORER_ADDRESS}${ROUTER_ADDRESS}`;

  return (
    <div className={styles.page}>
      <SiteNav active="explorer" />

      <section className={`${styles.section} ${x.head}`}>
        <div className={styles.sectionInner}>
          <span className={styles.eyebrow}>
            <span className={styles.eyebrowNum}>LIVE</span> / EXPLORER
          </span>
          <h1 className={x.title}>Every shipment, on the record.</h1>
          <p className={styles.sectionLede}>
            Read straight from the Portage Router on Arc Testnet. Open any shipment and the page
            re-derives it from raw calldata — the Circle attestation, the depositor&apos;s signature,
            the amount — so you don&apos;t have to take this site&apos;s word for it.
          </p>

          <div className={x.stats}>
            <div className={x.stat}>
              <span className={x.statKey}>Shipments cleared</span>
              <span className={x.statVal}>{result.ok ? cleared.length : "—"}</span>
            </div>
            <div className={x.stat}>
              <span className={x.statKey}>USDC cleared</span>
              <span className={x.statVal}>{result.ok ? formatUsdcFull(clearedTotal) : "—"}</span>
            </div>
            <div className={x.stat}>
              <span className={x.statKey}>Apps credited</span>
              <span className={x.statVal}>{result.ok ? apps.size : "—"}</span>
            </div>
            <div className={x.stat}>
              <span className={x.statKey}>Latest clearance</span>
              <span className={`${x.statVal} ${x.statValSm}`}>{formatUtc(latest)}</span>
            </div>
          </div>

          <div className={styles.manifest}>
            <div className={styles.manifestHead}>
              <span className={styles.manifestTitle}>Router ledger</span>
              {result.ok && rows.length > 0 ? (
                <span className={styles.liveChip}>
                  <span className={styles.liveDot} aria-hidden="true" />
                  Live · Arc Testnet
                </span>
              ) : null}
            </div>

            <div className={x.table} role="table" aria-label="Portage shipments">
              <div className={`${x.row} ${x.rowHead}`} role="row">
                <span role="columnheader">Cleared</span>
                <span role="columnheader">Waybill</span>
                <span role="columnheader">Amount</span>
                <span role="columnheader">Consignee</span>
                <span role="columnheader">Purpose</span>
                <span role="columnheader" className={x.right}>
                  Status
                </span>
              </div>

              {!result.ok ? (
                <div className={styles.mNotice}>
                  The ledger can&apos;t be read right now. The Router&apos;s events are public — read
                  them directly on the{" "}
                  <a className={styles.mNoticeLink} href={routerUrl} target="_blank" rel="noopener noreferrer">
                    Arc explorer
                  </a>
                  .
                </div>
              ) : rows.length === 0 ? (
                <div className={styles.mNotice}>
                  No shipments yet. This table fills from the Router&apos;s on-chain{" "}
                  <code className={styles.inlineCode}>Credited</code> events.
                </div>
              ) : (
                rows.map((r) => {
                  const held = r.status === "held";
                  return (
                    <a key={r.id} href={`/explorer/${r.txHash}`} className={x.row} role="row">
                      <span role="cell" data-label="Cleared" className={x.muted}>
                        {formatUtc(r.timestamp)}
                      </span>
                      <span role="cell" data-label="Waybill" className={x.hash}>
                        {middle(r.txHash)}
                      </span>
                      <span role="cell" data-label="Amount" className={x.amount}>
                        {formatUsdcFull(BigInt(r.amount))} <span className={x.unit}>USDC</span>
                      </span>
                      <span role="cell" data-label="Consignee">
                        {r.appId ? (
                          <>
                            {appName(r.appId)} <span className={x.muted}>/ {middle(r.account ?? "", 4, 4)}</span>
                          </>
                        ) : (
                          <span className={x.muted}>—</span>
                        )}
                      </span>
                      <span role="cell" data-label="Purpose" className={x.muted}>
                        {held ? quarantineReasonLabel(r.reason ?? 0) : actionLabel(r.action ?? 0)}
                      </span>
                      <span role="cell" data-label="Status" className={x.right}>
                        <span className={`${x.pill} ${held ? x.pillHeld : x.pillCleared}`}>
                          {held ? "HELD" : "CLEARED"}
                        </span>
                        <span className={x.go} aria-hidden="true">
                          →
                        </span>
                      </span>
                    </a>
                  );
                })
              )}
            </div>

            <div className={x.source}>
              {result.ok && result.source === "indexer"
                ? "Source: Arc explorer index, full Router history · decoded against the Router ABI here · refreshed every 60 s"
                : result.ok
                  ? "Source: direct RPC scan of the Router (explorer index unreachable — recent window only) · refreshed every 60 s"
                  : "Source unavailable"}
              <a className={x.sourceLink} href={routerUrl} target="_blank" rel="noopener noreferrer">
                Router {middle(ROUTER_ADDRESS)} ↗
              </a>
            </div>
          </div>
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
