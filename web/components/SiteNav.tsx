import styles from "../app/page.module.css";

export const REPO_URL = "https://github.com/erhnysr/portage";

/* ---------- brand mark: three converging lines + ink block, drawn straight on the ground ---------- */
export function Logo({ size }: { size: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 88 88" fill="none" aria-hidden="true">
      <rect x="40" y="30" width="34" height="28" rx="6" fill="#0B0D12" />
      <path d="M14 18 L40 44" stroke="#7C5CFC" strokeWidth="8" strokeLinecap="round" />
      <path d="M14 44 L40 44" stroke="#2775CA" strokeWidth="8" strokeLinecap="round" />
      <path d="M14 70 L40 44" stroke="#22D3EE" strokeWidth="8" strokeLinecap="round" />
    </svg>
  );
}

/** Site-wide sticky nav. `active` highlights the current top-level page. */
export function SiteNav({ active }: { active: "home" | "explorer" | "demo" }) {
  return (
    <nav className={styles.nav}>
      <div className={styles.navInner}>
        <a href="/" className={styles.brand} aria-label="Portage home">
          <Logo size={30} />
          <span className={styles.wordmark} aria-label="Portage">
            <span className={styles.wordmarkStrong}>Port</span>
            <span className={styles.wordmarkSoft}>age</span>
          </span>
        </a>

        <div className={styles.navRight}>
          <div className={styles.segments}>
            <a
              href="/demo"
              className={`${styles.segment} ${styles.segInk} ${active === "demo" ? styles.segActive : ""}`}
              aria-current={active === "demo" ? "page" : undefined}
            >
              Try it
            </a>
            <a
              href="/explorer"
              className={`${styles.segment} ${styles.segInk} ${active === "explorer" ? styles.segActive : ""}`}
              aria-current={active === "explorer" ? "page" : undefined}
            >
              Explorer
            </a>
            <a href="/#proof" className={`${styles.segment} ${styles.segPurple} ${styles.segHideMobile}`}>
              Proof
            </a>
            <a href="/#architecture" className={`${styles.segment} ${styles.segBlue} ${styles.segHideMobile}`}>
              Architecture
            </a>
            <a href="/#sdk" className={`${styles.segment} ${styles.segCyan} ${styles.segHideMobile}`}>
              SDK
            </a>
          </div>
          <span className={styles.navDivider} aria-hidden="true" />
          <span className={styles.statusPill}>
            <span className={styles.statusDot} aria-hidden="true" />
            Arc Testnet
          </span>
          <a href={REPO_URL} target="_blank" rel="noopener noreferrer" className={styles.launch}>
            View on GitHub
          </a>
        </div>
      </div>
    </nav>
  );
}
