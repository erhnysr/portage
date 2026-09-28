import type { Metadata } from "next";
import styles from "../page.module.css";
import x from "../explorer/explorer.module.css";
import { Logo, SiteNav } from "../../components/SiteNav";
import DemoFlow from "./DemoFlow";

export const metadata: Metadata = {
  title: "Live demo — Portage",
  description:
    "Move testnet USDC from Base Sepolia into a Portage ledger on Arc with your own wallet — then verify the receipt from calldata.",
};

export default function DemoPage() {
  return (
    <div className={styles.page}>
      <SiteNav active="demo" />

      <section className={`${styles.section} ${x.head}`}>
        <div className={styles.sectionInner}>
          <span className={styles.eyebrow}>
            <span className={styles.eyebrowNum}>LIVE</span> / DEMO · TESTNET
          </span>
          <h1 className={x.title}>Run a consolidation yourself.</h1>
          <p className={styles.sectionLede}>
            Your wallet, testnet USDC, real contracts. Deposit into Circle Gateway on Base Sepolia, sign two
            messages, and clear the payment into a Portage ledger on Arc in one transaction. Runs entirely in your
            browser on the published <code className={styles.inlineCode}>@erhnysr/portage-sdk</code> — no server holds a
            key.
          </p>
          <DemoFlow />
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
          Testnet only — no real funds. Arc™ is a trademark of Circle Internet Group, Inc. Portage is an independent
          project and is not affiliated with or endorsed by Circle. © 2026 Portage.
        </p>
      </footer>
    </div>
  );
}
