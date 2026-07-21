import styles from "./page.module.css";

export default function Home() {
  return (
    <div className={`${styles.page} p-texture`}>
      {/* ---------- nav ---------- */}
      <nav className={styles.nav}>
        <div className={styles.brand}>
          <span className={styles.brandName}>PORTAGE</span>
          <span className={styles.brandManifest}>MANIFEST No. 0X4B21-ARC</span>
        </div>
        <div className={styles.navLinks}>
          <a href="#proof">Proof</a>
          <a href="#architecture">Architecture</a>
          <a href="#sdk">SDK</a>
        </div>
      </nav>

      {/* ---------- hero ---------- */}
      <section className={styles.hero}>
        <div className={styles.heroKicker}>Cross-chain USDC payout consolidation</div>
        <div className={styles.heroGrid}>
          <div>
            <h1 className={styles.heroTitle}>
              Every chain
              <br />
              deposits. One
              <br />
              ledger <span className={styles.clears}>clears.</span>
            </h1>
            <p className={styles.heroSub}>
              Consolidated through Circle Gateway, cleared on Arc, released as one settled payout.
            </p>
            <div className={styles.heroCtas}>
              <a href="#proof" className={styles.btnPrimary}>
                View the proof →
              </a>
              <a href="#architecture" className={styles.btnGhost}>
                Read the architecture
              </a>
            </div>
          </div>

          <div>
            {/* technical docket */}
            <div className={styles.docket}>
              <div className={styles.docketHead}>Technical docket</div>
              <div className={styles.docketBody}>
                <div className={styles.docketRow}>
                  <span className={styles.docketKey}>PROTOCOL</span>
                  <span>Circle Gateway + Arc</span>
                </div>
                <div className={styles.docketRow}>
                  <span className={styles.docketKey}>SETTLEMENT</span>
                  <span>Native USDC</span>
                </div>
                <div className={`${styles.docketRow} ${styles.docketRowLast}`}>
                  <span className={styles.docketKey}>ATTESTATION</span>
                  <span>Circle Attestation Service</span>
                </div>
              </div>
            </div>

            {/* route diagram — everything lives inside the SVG viewBox so the wordmark, nodes
                and chain labels scale together and stay aligned at any container width */}
            <div className={styles.diagram}>
              <svg
                viewBox="0 0 340 240"
                width="100%"
                height="100%"
                preserveAspectRatio="xMidYMid meet"
                className={styles.diagramSvg}
              >
                <text x="220" y="120" textAnchor="middle" dominantBaseline="central" className={styles.diagramWord}>
                  ARC
                </text>
                <line x1="60" y1="30" x2="220" y2="120" stroke="#4C7D77" strokeWidth="1.2" className="p-flow" />
                <line x1="60" y1="120" x2="220" y2="120" stroke="#4C7D77" strokeWidth="1.2" className="p-flow" />
                <line x1="60" y1="210" x2="220" y2="120" stroke="#4C7D77" strokeWidth="1.2" className="p-flow" />
                <circle cx="60" cy="30" r="6" fill="#1C1730" stroke="#4C7D77" strokeWidth="1.5" className="p-node" style={{ animationDelay: "0s" }} />
                <circle cx="60" cy="120" r="6" fill="#1C1730" stroke="#4C7D77" strokeWidth="1.5" className="p-node" style={{ animationDelay: ".5s" }} />
                <circle cx="60" cy="210" r="6" fill="#1C1730" stroke="#4C7D77" strokeWidth="1.5" className="p-node" style={{ animationDelay: "1s" }} />
                <circle cx="220" cy="120" r="15" fill="#1C1730" stroke="#7C6FE0" strokeWidth="2" />
                <circle cx="220" cy="120" r="4" fill="#7C6FE0" className="p-node" />
                <text x="76" y="24" className={styles.diagramLabel}>BASE</text>
                <text x="76" y="114" className={styles.diagramLabel}>ETHEREUM</text>
                <text x="76" y="204" className={styles.diagramLabel}>ARBITRUM</text>
              </svg>
            </div>
          </div>
        </div>
      </section>

      {/* ---------- cleared shipments ---------- */}
      <section id="proof" className={styles.section}>
        <div className={styles.proofHead}>
          <div>
            <div className={styles.sectionKicker}>Proof, not promises</div>
            <h2 className={styles.sectionTitle}>Cleared shipments</h2>
          </div>
          <span className={styles.proofMeta}>Today&apos;s manifest entries</span>
        </div>

        <div className={styles.table}>
          <div className={`${styles.row} ${styles.tableHead}`}>
            <span>Waybill</span>
            <span>Route</span>
            <span>Cargo</span>
            <span>Consignee</span>
            <span className={styles.headRight}>Status</span>
          </div>

          <div className={`${styles.row} ${styles.tableRow}`}>
            <span className={styles.cellWaybill} data-label="Waybill">0xf1aa545e — spec hash</span>
            <span className={styles.cellRoute} data-label="Route">SPEC → ARC</span>
            <span data-label="Cargo">—</span>
            <span className={styles.cellConsignee} data-label="Consignee">Payout spec commitment</span>
            <span className={styles.cellStatus} data-label="Status">CLEARED</span>
          </div>
          <div className={`${styles.row} ${styles.tableRow}`}>
            <span className={styles.cellWaybill} data-label="Waybill">0x2a3f0411 — mint tx</span>
            <span className={styles.cellRoute} data-label="Route">GATEWAY → ARC</span>
            <span data-label="Cargo">Consolidated USDC</span>
            <span className={styles.cellConsignee} data-label="Consignee">executeMintWithMeta</span>
            <span className={styles.cellStatus} data-label="Status">CLEARED</span>
          </div>
          <div className={`${styles.row} ${styles.tableRow} ${styles.tableRowLast}`}>
            <span className={styles.cellWaybill} data-label="Waybill">0x92c99b39 — deploy tx</span>
            <span className={styles.cellRoute} data-label="Route">ARC MAINNET</span>
            <span data-label="Cargo">Contract deploy</span>
            <span className={styles.cellConsignee} data-label="Consignee">Portage clearinghouse</span>
            <span className={styles.cellStatus} data-label="Status">CLEARED</span>
          </div>
        </div>
      </section>

      {/* ---------- how a shipment clears ---------- */}
      <section id="architecture" className={styles.section}>
        <div className={styles.sectionKicker}>Architecture</div>
        <h2 className={styles.sectionTitle} style={{ marginBottom: 32 }}>
          How a shipment clears
        </h2>

        <div className={styles.steps}>
          <div className={styles.step}>
            <span className={styles.stepCode}>DEP-01</span>
            <span className={styles.stepName}>Deposit</span>
            <span className={styles.stepDesc}>
              USDC lands on Base, Ethereum, or Arbitrum. Portage registers the deposit against
              Circle Gateway&apos;s unified balance — no bridging, no wrapped assets.
            </span>
          </div>
          <div className={styles.step}>
            <span className={styles.stepCode}>CON-02</span>
            <span className={styles.stepName}>Consolidate</span>
            <span className={styles.stepDesc}>
              Deposits across chains are batched into a single manifest entry, netted against
              pending payouts, and queued for the next clearing window.
            </span>
          </div>
          <div className={styles.step}>
            <span className={styles.stepCode}>CLR-03</span>
            <span className={styles.stepName}>Clear</span>
            <span className={styles.stepDesc}>
              Arc executes <span className={styles.accent}>executeMintWithMeta</span>, minting the
              consolidated balance with an attached metadata trail linking back to every origin
              deposit.
            </span>
          </div>
          <div className={`${styles.step} ${styles.stepLast}`}>
            <span className={styles.stepCode}>REL-04</span>
            <span className={styles.stepName}>Release</span>
            <span className={styles.stepDesc}>
              A single USDC payout is released to the consignee, with the full route manifest
              attached for reconciliation.
            </span>
          </div>
        </div>
      </section>

      {/* ---------- sdk ---------- */}
      <section id="sdk" className={styles.section}>
        <div className={styles.sectionKicker}>Integration</div>
        <h2 className={styles.sectionTitle} style={{ marginBottom: 28 }}>
          Four calls to a cleared payout
        </h2>

        <div className={styles.sdkCard}>
          <div className={styles.sdkCardHead}>
            <span>payout.ts</span>
            <span>portage-sdk@2.3.0</span>
          </div>
          <pre className={styles.code}>
            <span className={styles.tokKw}>import</span> {"{ PortageClient, PortagePayouts }"}{" "}
            <span className={styles.tokKw}>from</span>{" "}
            <span className={styles.tokStr}>&quot;@portage/sdk&quot;</span>
            {"\n\n"}
            <span className={styles.tokKw}>const</span> client = <span className={styles.tokKw}>new</span>{" "}
            PortageClient({"{ network: "}
            <span className={styles.tokStr}>&quot;arc-mainnet&quot;</span>
            {" }"})
            {"\n\n"}
            <span className={styles.tokCm}>
              {"// DEP-01 — register an incoming deposit via the origin-chain wallet client"}
            </span>
            {"\n"}
            <span className={styles.tokKw}>await</span> client.deposit(walletClient, {"{ chain: "}
            <span className={styles.tokStr}>&quot;base&quot;</span>
            {", amount: "}
            <span className={styles.tokStr}>&quot;42500.00&quot;</span>
            {" }"})
            {"\n\n"}
            <span className={styles.tokCm}>
              {"// CON-02 — build and submit the consolidation intent across origins"}
            </span>
            {"\n"}
            <span className={styles.tokKw}>const</span> intent = <span className={styles.tokKw}>await</span>{" "}
            client.buildConsolidationIntent()
            {"\n"}
            <span className={styles.tokKw}>const</span> consolidation ={" "}
            <span className={styles.tokKw}>await</span> client.submitConsolidation(intent)
            {"\n\n"}
            <span className={styles.tokCm}>{"// CLR-03 — clear on Arc with full metadata trail"}</span>
            {"\n"}
            <span className={styles.tokKw}>const</span> clearance = <span className={styles.tokKw}>await</span>{" "}
            client.executeMintWithMeta(consolidation.id)
            {"\n\n"}
            <span className={styles.tokCm}>
              {"// REL-04 — release the settled payout to the consignee"}
            </span>
            {"\n"}
            <span className={styles.tokKw}>const</span> payouts = <span className={styles.tokKw}>new</span>{" "}
            PortagePayouts({"{ network: "}
            <span className={styles.tokStr}>&quot;arc-mainnet&quot;</span>
            {" }"})
            {"\n"}
            <span className={styles.tokKw}>await</span> payouts.payout({"{ referenceId: clearance.id, recipient: "}
            <span className={styles.tokStr}>&quot;0x71c9...4a2f&quot;</span>
            {", amount: "}
            <span className={styles.tokStr}>&quot;42500.00&quot;</span>
            {" }"})
          </pre>
        </div>
      </section>

      {/* ---------- footer ---------- */}
      <footer className={styles.footer}>
        <div className={styles.stats}>
          <div>
            <div className={styles.statNum}>81</div>
            <div className={styles.statLabel}>Tests passing</div>
          </div>
          <div>
            <div className={styles.statNum}>9</div>
            <div className={styles.statLabel}>Invariants enforced</div>
          </div>
          <div>
            <div className={styles.statNum}>0 / 65,000</div>
            <div className={styles.statLabel}>Reverts across fuzz calls</div>
          </div>
        </div>

        <div className={styles.footerLegal}>
          <span>
            Portage is built on Arc. Arc™ is a trademark of Circle Internet Group, Inc. Portage is
            an independent project and is not affiliated with or endorsed by Circle.
          </span>
          <span className={styles.copy}>© 2026 Portage</span>
        </div>
      </footer>
    </div>
  );
}
