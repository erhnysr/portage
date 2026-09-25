import styles from "./page.module.css";
import { ARC_EXPLORER_ADDRESS, ARC_EXPLORER_TX, ROUTER_ADDRESS, short } from "../lib/portage";
import { getShipments } from "../lib/shipments";

// The manifest is real on-chain proof: it reads the Router's Credited/Quarantined events
// from Arc Testnet. ISR — revalidate the (server-side, windowed) scan at most once a minute;
// between revalidations every visitor is served cached HTML.
export const revalidate = 60;

const REPO_URL = "https://github.com/erhnysr/portage";
const SDK_URL = "https://www.npmjs.com/package/@erhnysr/portage-sdk";
const ROUTER_ON_ARCSCAN = `${ARC_EXPLORER_ADDRESS}${ROUTER_ADDRESS}`;

/* ---------- brand mark: three converging lines + ink block, drawn straight on the ground ---------- */
function Logo({ size }: { size: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 88 88" fill="none" aria-hidden="true">
      <rect x="40" y="30" width="34" height="28" rx="6" fill="#0B0D12" />
      <path d="M14 18 L40 44" stroke="#7C5CFC" strokeWidth="8" strokeLinecap="round" />
      <path d="M14 44 L40 44" stroke="#2775CA" strokeWidth="8" strokeLinecap="round" />
      <path d="M14 70 L40 44" stroke="#22D3EE" strokeWidth="8" strokeLinecap="round" />
    </svg>
  );
}

/* ---------- blurred brand blob for section backgrounds (z-index:0; content sits at z-index:1) ---------- */
function Blob({ id, className }: { id: string; className: string }) {
  return (
    <svg
      className={className}
      viewBox="0 0 600 400"
      preserveAspectRatio="xMidYMid slice"
      aria-hidden="true"
    >
      <defs>
        <filter id={id} x="-40%" y="-40%" width="180%" height="180%">
          <feGaussianBlur stdDeviation="70" />
        </filter>
      </defs>
      <g filter={`url(#${id})`}>
        <circle cx="170" cy="150" r="120" fill="#7C5CFC" opacity="0.14" />
        <circle cx="340" cy="110" r="110" fill="#2775CA" opacity="0.12" />
        <circle cx="430" cy="240" r="130" fill="#22D3EE" opacity="0.13" />
      </g>
    </svg>
  );
}

// SDK code sample — faithful to the real @erhnysr/portage-sdk API (see sdk/README.md).
type Tok = { t: "kw" | "str" | "num" | "com" | "fn" | "plain"; v: string };
const CODE: Tok[][] = [
  [{ t: "kw", v: "import" }, { t: "plain", v: " { PortageClient, appIdFromName } " }, { t: "kw", v: "from" }, { t: "plain", v: " " }, { t: "str", v: '"@erhnysr/portage-sdk"' }],
  [],
  [{ t: "com", v: "// Non-custodial: signs with the user's own wallet, never holds keys" }],
  [{ t: "kw", v: "const" }, { t: "plain", v: " portage = " }, { t: "kw", v: "new" }, { t: "plain", v: " " }, { t: "fn", v: "PortageClient" }, { t: "plain", v: "({ network: " }, { t: "str", v: '"arcTestnet"' }, { t: "plain", v: ", arcPublicClient })" }],
  [],
  [{ t: "com", v: "// 1 · Deposit USDC into Circle Gateway's unified balance" }],
  [{ t: "kw", v: "await" }, { t: "plain", v: " portage." }, { t: "fn", v: "deposit" }, { t: "plain", v: "(wallet, { chain: " }, { t: "str", v: '"baseSepolia"' }, { t: "plain", v: ", amount: " }, { t: "num", v: "5_000000n" }, { t: "plain", v: " })" }],
  [],
  [{ t: "com", v: "// 2 · Build + sign the consolidation intent" }],
  [{ t: "kw", v: "const" }, { t: "plain", v: " intent = portage." }, { t: "fn", v: "buildConsolidationIntent" }, { t: "plain", v: "({ sourceChain: " }, { t: "str", v: '"baseSepolia"' }, { t: "plain", v: ", amount: " }, { t: "num", v: "5_000000n" }, { t: "plain", v: ", depositor })" }],
  [{ t: "kw", v: "const" }, { t: "plain", v: " burnSig = " }, { t: "kw", v: "await" }, { t: "plain", v: " wallet." }, { t: "fn", v: "signTypedData" }, { t: "plain", v: "({ account: depositor, ...intent.typedData })" }],
  [],
  [{ t: "com", v: "// 3 · Submit for a Circle attestation" }],
  [{ t: "kw", v: "const" }, { t: "plain", v: " { attestation, signature } = " }, { t: "kw", v: "await" }, { t: "plain", v: " portage." }, { t: "fn", v: "submitConsolidation" }, { t: "plain", v: "(intent, burnSig)" }],
  [],
  [{ t: "com", v: "// 4 · Clear on Arc — atomic mint + credit into the app ledger" }],
  [{ t: "kw", v: "await" }, { t: "plain", v: " portage." }, { t: "fn", v: "executeMintWithMeta" }, { t: "plain", v: "(arcWallet, { attestation, signature, meta, metaSig })" }],
];

const tokClass: Record<Tok["t"], string> = {
  kw: styles.tKw,
  str: styles.tStr,
  num: styles.tNum,
  com: styles.tCom,
  fn: styles.tFn,
  plain: styles.tPlain,
};

export default async function Home() {
  const manifest = await getShipments();

  return (
    <div className={styles.page}>
      {/* ---------- nav ---------- */}
      <nav className={styles.nav}>
        <div className={styles.navInner}>
          <a href="#top" className={styles.brand} aria-label="Portage home">
            <Logo size={30} />
            <span className={styles.wordmark}>Portage</span>
          </a>

          <div className={styles.navRight}>
            <div className={styles.segments}>
              <a href="#proof" className={`${styles.segment} ${styles.segPurple}`}>
                Proof
              </a>
              <a href="#architecture" className={`${styles.segment} ${styles.segBlue}`}>
                Architecture
              </a>
              <a href="#sdk" className={`${styles.segment} ${styles.segCyan}`}>
                SDK
              </a>
            </div>
            <span className={styles.navDivider} aria-hidden="true" />
            <span className={styles.statusPill}>
              <span className={styles.statusDot} aria-hidden="true" />
              Arc Testnet
            </span>
            <a
              href={REPO_URL}
              target="_blank"
              rel="noopener noreferrer"
              className={styles.launch}
            >
              View on GitHub
            </a>
          </div>
        </div>
      </nav>

      {/* ---------- hero ---------- */}
      <header id="top" className={styles.hero}>
        <div className={styles.heroGrid} aria-hidden="true" />
        <svg
          className={styles.heroMesh}
          viewBox="0 0 1200 620"
          preserveAspectRatio="xMidYMid slice"
          aria-hidden="true"
        >
          <defs>
            <filter id="heroBlur" x="-30%" y="-30%" width="160%" height="160%">
              <feGaussianBlur stdDeviation="70" />
            </filter>
            <linearGradient id="heroFade" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="#fff" stopOpacity="1" />
              <stop offset="100%" stopColor="#fff" stopOpacity="0" />
            </linearGradient>
            <mask id="heroMask">
              <rect width="1200" height="620" fill="url(#heroFade)" />
            </mask>
          </defs>
          <g filter="url(#heroBlur)" mask="url(#heroMask)">
            <ellipse cx="300" cy="150" rx="280" ry="190" fill="#7C5CFC" opacity="0.5" />
            <ellipse cx="720" cy="110" rx="320" ry="210" fill="#2775CA" opacity="0.45" />
            <ellipse cx="1000" cy="240" rx="260" ry="200" fill="#22D3EE" opacity="0.4" />
          </g>
        </svg>

        <div className={styles.heroInner}>
          <span className={styles.badge}>
            <span className={styles.badgeDot} aria-hidden="true" />
            Built on Circle Gateway
          </span>
          <h1 className={styles.heroTitle}>
            Every chain deposits.
            <br />
            One ledger <span className={styles.grad}>clears.</span>
          </h1>
          <p className={styles.heroSub}>
            Apps that collect USDC across chains have to reconcile balances everywhere before they
            can pay anyone out. Portage routes each deposit through Circle Gateway into a single
            per-app balance on Arc — so you clear and pay from one ledger, with no bridging and no
            wrapped tokens.
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
      </header>

      {/* ---------- docket strip ---------- */}
      <section className={styles.docket}>
        <div className={styles.docketCell}>
          <span className={styles.docketKey}>Protocol</span>
          <span className={styles.docketVal}>Circle Gateway + Arc</span>
        </div>
        <div className={styles.docketCell}>
          <span className={styles.docketKey}>Settlement</span>
          <span className={styles.docketVal}>Native USDC</span>
        </div>
        <div className={styles.docketCell}>
          <span className={styles.docketKey}>Attestation</span>
          <span className={styles.docketVal}>Circle Attestation Service</span>
        </div>
        <div className={styles.docketCell}>
          <span className={styles.docketKey}>Chains</span>
          <span className={styles.docketVal}>Base Sepolia → Arc</span>
        </div>
      </section>

      {/* ---------- trust strip ---------- */}
      <section className={styles.trust}>
        <div className={styles.trustItem}>
          <TrustIcon kind="code" />
          <span>Open source</span>
        </div>
        <div className={styles.trustItem}>
          <TrustIcon kind="shield" />
          <span>393,000+ fuzz calls, 0 reverts across core solvency invariants</span>
        </div>
        <div className={styles.trustItem}>
          <TrustIcon kind="star" />
          <span>Built for the Arc Builder Program</span>
        </div>
        <div className={styles.trustItem}>
          <TrustIcon kind="check" />
          <span>Deployed and verified on Arc Testnet</span>
        </div>
      </section>

      {/* ---------- proof ---------- */}
      <section id="proof" className={styles.section}>
        <Blob id="blobProof" className={styles.blobProof} />
        <div className={styles.sectionInner}>
          <span className={styles.eyebrow}>
            <span className={styles.eyebrowNum}>01</span> / PROOF
          </span>
          <h2 className={styles.sectionTitle}>Deposits in, one payout out.</h2>
          <p className={styles.sectionLede}>
            Every deposit lands in Circle Gateway&apos;s unified balance, clears atomically on Arc,
            and settles into a single per-app ledger balance you draw down on demand.
          </p>

          <div className={styles.proofCards}>
            <article className={styles.card}>
              <span className={styles.cardTag}>Deposited</span>
              <p className={styles.cardBody}>
                USDC arrives on a source chain and is registered against the Gateway unified
                balance — no bridging, no wrapped assets.
              </p>
            </article>
            <article className={styles.card}>
              <span className={styles.cardTag}>In transit</span>
              <p className={styles.cardBody}>
                A signed burn intent is attested by Circle, pinning the destination caller to
                Portage&apos;s forwarder so nothing can be misrouted.
              </p>
            </article>
            <article className={`${styles.card} ${styles.cardAccent}`}>
              <span className={styles.cardTag}>Cleared</span>
              <p className={styles.cardBody}>
                Arc mints and credits in one atomic call. The app balance grows; solvency holds by
                construction.
              </p>
            </article>
          </div>

          <div className={styles.manifest}>
            <div className={styles.manifestHead}>
              <span className={styles.manifestTitle}>Manifest</span>
              {manifest.ok && manifest.shipments.length > 0 ? (
                <span className={styles.liveChip}>
                  <span className={styles.liveDot} aria-hidden="true" />
                  Live · Arc Testnet
                </span>
              ) : null}
            </div>
            <div className={styles.manifestTable}>
              <div className={`${styles.mRow} ${styles.mHead}`}>
                <span>Waybill</span>
                <span>Cargo</span>
                <span>Consignee</span>
                <span className={styles.mRight}>Status</span>
              </div>

              {!manifest.ok ? (
                <div className={styles.mNotice}>
                  Live manifest temporarily unavailable — read the Router directly on{" "}
                  <a
                    className={styles.mNoticeLink}
                    href={ROUTER_ON_ARCSCAN}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    Arcscan
                  </a>
                  .
                </div>
              ) : manifest.shipments.length === 0 ? (
                <div className={styles.mNotice}>
                  No cleared shipments yet — this table fills from the Router&apos;s on-chain{" "}
                  <code className={styles.inlineCode}>Credited</code> events. Check back after the
                  next deposit.
                </div>
              ) : (
                manifest.shipments.map((s) => {
                  const held = s.status === "held";
                  return (
                    <div key={s.id} className={styles.mRow}>
                      <span data-label="Waybill" className={styles.mMono}>
                        <a
                          className={styles.mLink}
                          href={`${ARC_EXPLORER_TX}${s.txHash}`}
                          target="_blank"
                          rel="noopener noreferrer"
                        >
                          {short(s.txHash)} — tx
                        </a>
                      </span>
                      <span data-label="Cargo" className={styles.mMono}>
                        {s.cargo}
                      </span>
                      <span data-label="Consignee" className={styles.mMono}>
                        {s.consignee}
                      </span>
                      <span
                        data-label="Status"
                        className={`${styles.mRight} ${styles.mStatus} ${
                          held ? styles.mHeld : styles.mCleared
                        }`}
                      >
                        {held ? "HELD" : "CLEARED"}
                      </span>
                    </div>
                  );
                })
              )}
            </div>
            <a
              href={ROUTER_ON_ARCSCAN}
              target="_blank"
              rel="noopener noreferrer"
              className={styles.liveLink}
            >
              View live data on Arcscan →
            </a>
          </div>
        </div>
      </section>

      {/* ---------- architecture ---------- */}
      <section id="architecture" className={styles.section}>
        <Blob id="blobArch" className={styles.blobArch} />
        <div className={styles.sectionInner}>
          <span className={styles.eyebrow}>
            <span className={styles.eyebrowNum}>02</span> / ARCHITECTURE
          </span>
          <h2 className={styles.sectionTitle}>Four steps, one ledger.</h2>
          <p className={styles.sectionLede}>
            An immutable core — registry, ledger, payout engine — with a thin periphery that lands
            mints and quarantines anything malformed. Funds never sit anywhere they can be
            mis-credited.
          </p>

          <div className={styles.stepGrid}>
            <article className={styles.card}>
              <span className={styles.stepCode}>DEP-01</span>
              <h3 className={styles.stepName}>Deposit</h3>
              <p className={styles.cardBody}>
                USDC lands on a source chain and is registered against Circle Gateway&apos;s unified
                balance.
              </p>
            </article>
            <article className={styles.card}>
              <span className={styles.stepCode}>CON-02</span>
              <h3 className={styles.stepName}>Consolidate</h3>
              <p className={styles.cardBody}>
                A signed burn intent binds the deposit&apos;s metadata to its spec hash, ready for
                attestation.
              </p>
            </article>
            <article className={styles.card}>
              <span className={styles.stepCode}>CLR-03</span>
              <h3 className={styles.stepName}>Clear</h3>
              <p className={styles.cardBody}>
                Arc runs <code className={styles.inlineCode}>executeMintWithMeta</code>, minting and
                crediting the ledger in one atomic call.
              </p>
            </article>
            <article className={`${styles.card} ${styles.cardAccent}`}>
              <span className={styles.stepCode}>REL-04</span>
              <h3 className={styles.stepName}>Release</h3>
              <p className={styles.cardBody}>
                The payout engine releases a single settled USDC payment to the consignee, gated by
                the app&apos;s controller.
              </p>
            </article>
          </div>
        </div>
      </section>

      {/* ---------- sdk ---------- */}
      <section id="sdk" className={styles.section}>
        <Blob id="blobSdk" className={styles.blobSdk} />
        <div className={styles.sectionInner}>
          <span className={styles.eyebrow}>
            <span className={styles.eyebrowNum}>03</span> / SDK
          </span>
          <div className={styles.sdkGrid}>
            <div className={styles.sdkCopy}>
              <h2 className={styles.sectionTitle}>Four calls to a cleared payout.</h2>
              <p className={styles.sectionLede}>
                <code className={styles.inlineCode}>@erhnysr/portage-sdk</code> is a non-custodial
                TypeScript client. Users sign burn intents with their own wallet; the SDK never
                holds keys. Amounts are atomic USDC units.
              </p>
              <a
                href={SDK_URL}
                target="_blank"
                rel="noopener noreferrer"
                className={styles.sdkDocsLink}
              >
                Read the SDK docs →
              </a>
            </div>

            <div className={styles.codeWindow}>
              <div className={styles.codeBar}>
                <span className={styles.dotRed} />
                <span className={styles.dotAmber} />
                <span className={styles.dotGreen} />
                <span className={styles.codeFile}>consolidate.ts</span>
              </div>
              <pre className={styles.code}>
                <code>
                  {CODE.map((line, i) => (
                    <span key={i} className={styles.codeLine}>
                      {line.length === 0
                        ? " "
                        : line.map((tok, j) => (
                            <span key={j} className={tokClass[tok.t]}>
                              {tok.v}
                            </span>
                          ))}
                      {"\n"}
                    </span>
                  ))}
                </code>
              </pre>
            </div>
          </div>
        </div>
      </section>

      {/* ---------- footer / metrics ---------- */}
      <footer className={styles.footer}>
        <div className={styles.metrics}>
          <div className={styles.metric}>
            <div className={styles.metricNum}>232</div>
            <div className={styles.metricLabel}>Tests passing</div>
          </div>
          <div className={styles.metric}>
            <div className={styles.metricNum}>12</div>
            <div className={styles.metricLabel}>Invariants enforced</div>
          </div>
          <div className={styles.metric}>
            <div className={styles.metricNum}>
              0 <span className={styles.metricOf}>/ 393,000</span>
            </div>
            <div className={styles.metricLabel}>Reverts · core solvency invariants</div>
          </div>
        </div>

        <div className={styles.footerBottom}>
          <a href="#top" className={styles.brand} aria-label="Portage home">
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

/* ---------- small inline icons for the trust strip ---------- */
function TrustIcon({ kind }: { kind: "code" | "shield" | "star" | "check" }) {
  const common = {
    width: 18,
    height: 18,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.8,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true,
  };
  switch (kind) {
    case "code":
      return (
        <svg {...common}>
          <path d="M8 6l-6 6 6 6" />
          <path d="M16 6l6 6-6 6" />
        </svg>
      );
    case "shield":
      return (
        <svg {...common}>
          <path d="M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z" />
          <path d="M9 12l2 2 4-4" />
        </svg>
      );
    case "star":
      return (
        <svg {...common}>
          <path d="M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17.8 6.6 20l1-6.1L3.2 9.5l6.1-.9z" />
        </svg>
      );
    case "check":
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="9" />
          <path d="M8.5 12.5l2.5 2.5 4.5-5" />
        </svg>
      );
  }
}
