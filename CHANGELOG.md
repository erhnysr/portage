# Changelog

## 0.2.0 — SDK and site (2026-11)

### SDK (`@erhnysr/portage-sdk`)
- **Arc mainnet pilot network.** `getNetwork("arcMainnet")` and `network: "arcMainnet"` now
  resolve to the capped-pilot deployment (addresses match the forge broadcast and are verified
  on explorer.arc.io). Mainnet source chains: `base`, `ethereum`, `arbitrum`, `avalanche`.
  The conditional-settlement layer and the Arena stay `PENDING` on mainnet.
- **Network-keyed config.** `NetworkConfig` per network; `getNetwork`, `isNetworkAvailable`,
  `conditionAddress`. The flat 0.1.x exports (`ARC`, `GATEWAY`, `PORTAGE_ARC_TESTNET`,
  `SOURCE_CHAINS`) remain as deprecated Arc Testnet aliases.
- **Clear errors for unsupported source chains** (`sourceChainInfo`), e.g. `baseSepolia` on mainnet.
- **Typing fix.** `deposit({ sourcePublicClient })` and `waitForAllowance` accept a client for any
  chain. In 0.1.0 a Base or other OP-stack client failed to typecheck.
- Conditional settlement (`ConditionalEscrow`, conditions, deals) on Arc Testnet.
- README examples are complete: imports, relayer account, and deposit headroom for `maxFee`.

### Site
- Mainnet pilot proof: link to the first Base → Arc consolidation on Arc mainnet.
- Test count updated to 246 (re-run 2026-11-05); "Free during the pilot"; footer links to docs,
  GitHub, security policy and license.

### Repo
- `SECURITY.md`, `CHANGELOG.md`, `docs/QUICKSTART.md`, runnable `examples/`.

## Contracts — hardening (2026-10)
- `executeMint` rejects empty `hookData`; governor-only `adoptOrphan` moves unaccounted router
  balance into quarantine; deploy scripts refuse chain 5042 without explicit mainnet minter,
  governor and guardian. 14 tests.
- Capped pilot deployed on Arc mainnet (2026-10-15); first live Base → Arc consolidation.

## 0.1.0 — 2026-08-22
- First SDK release: `PortageClient` and `PortagePayouts`. Contracts deployed and verified on Arc Testnet.
