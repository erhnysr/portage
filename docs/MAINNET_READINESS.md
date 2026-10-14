# Portage — Mainnet readiness

**Status (2026-10-14): NOT ready for mainnet.** Portage v0.1 runs on Arc Testnet only. The contracts
are unaudited and no mainnet deployment exists. This document lists what is verified, what is not,
and what must happen before real USDC is held.

## 1. Arc mainnet facts (verified on-chain and against the live Gateway API, 2026-10-14)

| Item | Value | Verified how |
|------|-------|--------------|
| Chain ID | `5042` | `eth_chainId` on `https://rpc.mainnet.arc.io` returned `0x13b2` |
| Gas token | USDC (18 decimals native; ERC-20 interface uses 6) | docs.arc.io / references / connect-to-arc |
| RPC (primary) | `https://rpc.mainnet.arc.io` | answered JSON-RPC (above) |
| Explorer | `https://explorer.arc.io` (Blockscout; `/address/<addr>` page and `/api/v2` answer) | fetched |
| CCTP / Gateway domain | `26` | `GET https://gateway-api.circle.com/v1/info` lists `26 Arc Mainnet` |
| USDC (ERC-20 interface) | `0x3600000000000000000000000000000000000000` | explorer: verified `FiatTokenProxy` → `NativeFiatTokenV2_2` |
| Gateway Wallet | `0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE` | `/v1/info` (domain 26 `walletContract`); explorer: verified ERC1967 proxy → `GatewayWallet`; `eth_getCode` non-empty |
| Gateway Minter | `0x2222222d7164433c4C09B0b0D809a9b52C04C205` | `/v1/info` (domain 26 `minterContract`); explorer: verified ERC1967 proxy; `eth_getCode` non-empty; `AttestationUsed` events on 2026-10-14 (live mints) |
| Gateway API | `https://gateway-api.circle.com` | `/v1/info` returned 200 with 13 mainnet domains |
| Gateway on source chains | same Wallet / Minter addresses on Ethereum (0), Avalanche (1), Optimism (2), Arbitrum (3), Base (6), Polygon (7), Unichain (10), Sonic (13), World Chain (14), Sei (16), HyperEVM (19); Solana (5) uses program ids | `/v1/info` |
| Source-chain USDC | Ethereum `0xA0b8…eB48` (dom 0), Avalanche `0xB97E…8a6E` (dom 1), Arbitrum `0xaf88…5831` (dom 3), Base `0x8335…2913` (dom 6) | developers.circle.com / stablecoins / usdc-contract-addresses (docs only) |

These are exported from `sdk/src/config.ts` (`ARC_MAINNET_CHAIN`, `ARC_MAINNET_GATEWAY`,
`MAINNET_SOURCE_CHAINS`). `NETWORKS.arcMainnet` stays `PENDING` until Portage is deployed.

**Still not verified:** that the Gateway API accepts and attests a burn intent whose
`destinationRecipient` is a Portage router on Arc mainnet. Do that with a small capped transfer
right after deploy (blocker 2).

Explorer note: `testnet.arcscan.app` (used in the SDK and web app) now redirects to
`explorer.testnet.arc.io`, the name the docs list. Links still work; switch the constants when convenient.

## 2. Testnet state (read on-chain 2026-10-14)

`Ledger.creditor == Router`, `Ledger.debitor == PayoutEngine`, `Router.forwarder == MintForwarder`
(`0x6547…aaed`). Registered apps: `coliseum` and `portage-demo`. Guardian: **unset** (`address(0)`).
Owner of AppRegistry, Ledger and Router: the deployer EOA `0xD346…B29F`, no pending owner.
`custodyTotal` 2.4 USDC, `quarantinedTotal` 0.

Evidence tx `0x088f3c7e…f32090`: log 5 Mint (0.5 USDC → Router), log 7 `AttestationUsed` (source
domain 6), log 9 Router → Ledger transfer, **log 10 `Ledger.Credited`** (app `portage-demo`,
0.5 USDC, transferId = specHash), log 11 `Router.Credited`, log 12 `MintExecuted`. Mint and ledger
credit happen in one transaction.

## 3. Tests (run 2026-10-14)

`forge test` with forge 1.5.1 / solc 0.8.28 on this tree (contracts identical to `935a91a`):
**232 passed, 0 failed** across 21 suites. Portage core + periphery account for **81** of them
(16 AppRegistry, 16 Ledger, 13 PayoutEngine, 11 MintForwarder, 13 Router, 12 invariant); the rest
are the Arena and conditional-escrow layers. OpenZeppelin submodule is v5.1.0.

## 4. Findings from the code review

| # | Severity for mainnet | Finding | Where |
|---|------|---------|-------|
| A | **Medium** | **Front-run into quarantine.** `executeMint` (forward-compat path) is permissionless and accepts empty `hookData`. Every v0.1 burn intent has empty `hookData`, so anyone who sees the attestation (e.g. in the mempool) can call `executeMint` first: the mint succeeds, empty meta decodes as malformed, and the deposit is quarantined instead of credited. The depositor's `executeMintWithMeta` then reverts (attestation already used). No funds are lost, but every deposit can be griefed into manual governor resolution. Demonstrated with a test against the current code. | `PortageMintForwarder.sol:93-106`, `PortageRouter.sol:131-135` |
| B | **Medium** | **Orphaned USDC is unrecoverable.** If a burn intent names the router as recipient but leaves `destinationCaller` unset, anyone can mint it directly through the GatewayMinter; the USDC reaches the router with no credit and no quarantine entry, and no function can move it. Same for plain transfers to the router. Threat T4 in `ARCHITECTURE.md` only holds when the intent is built correctly. Demonstrated with a test against the current code. | `PortageRouter.sol:40-44`, `:103-113` |
| C | Low | Smart-contract wallets cannot use `executeMintWithMeta`: the meta signature is checked with `ECDSA.recover` only (no ERC-1271). | `PortageMintForwarder.sol:82-83` |
| D | Low | Excess USDC sent directly to the Ledger (above `custodyTotal`) is also stranded; invariant I1 is `>=`. | `Ledger.sol:27` |
| 1 | High (ops) | Governor is the deployer EOA on testnet. All wiring and quarantine recovery are `onlyOwner`. Mainnet needs a multisig. Ownership uses `Ownable2Step`. | `AppRegistry.sol:17`, `Ledger.sol:31`, `PortageRouter.sol:24` |
| 2 | High (ops) | No guardian by default; testnet has none. Without it only each app's owner can pause. | `Deploy.s.sol:69`, `AppRegistry.sol:68` |
| 3 | Medium | Only circuit breaker is per-app and halts outflows only. Deposits cannot be paused; no global pause. | `Ledger.sol:154`, `PortageRouter.sol:142-144` |
| 4 | Medium | No per-deposit or per-app caps. A pilot must be limited operationally. | `Ledger.sol:121-141` |
| 5 | Info | Governor can send quarantined funds to any address or credit them to any registered app. Trust assumption to disclose. | `PortageRouter.sol:90`, `:103` |
| 6 | High (deploy) | `Deploy.s.sol` and `DeployForwarder.s.sol` default the GatewayMinter to the **testnet** minter; `DeployForwarder` also defaults to the testnet router. USDC is the same address on both networks. A mainnet run without explicit overrides would wire the testnet minter. | `Deploy.s.sol:32-33`, `:46-47`; `DeployForwarder.s.sol:29-31`, `:34-36` |
| 7 | Low | When the governor is a multisig, `Deploy.s.sol` prints the wiring calls but omits `registry.setGuardian(guardian)`. | `Deploy.s.sol:96-99` |
| 8 | Info | EIP-712 domain binds `chainId` and the forwarder address, so testnet meta signatures are invalid on mainnet. | `PortageMintForwarder.sol:54`, `sdk/src/client.ts:198-202` |
| 9 | Info | Ledger and Router both emit an event named `Credited` with different signatures. Indexers must filter by address. | `Ledger.sol:64`, `PortageRouter.sol:51-53` |
| 10 | Info | `Ledger.credit` comment says CEI, but the code pulls tokens before writing state. Safe here (`onlyCreditor`, `nonReentrant`, USDC has no hooks); fix the comment. | `Ledger.sol:115-116` vs `:130-137` |
| 11 | Medium | Web app hardcodes testnet chain, explorer and RPC. Needs a network-aware pass before any mainnet UI. `web` also has a pre-existing type error (cannot find module `@erhnysr/portage-sdk` in `app/demo/DemoFlow.tsx`). | `web/lib/portage.ts`, `web/lib/shipments.ts`, `web/app/demo/chains.ts` |

**Fixes for A, B, 6 and 7 are prepared on the local branch `hardening/mainnet-prep`** (not merged,
not deployed): `executeMint` rejects empty `hookData`, the router gains a governor-only
`adoptOrphan(specHash, amount)` that moves only unaccounted balance into quarantine, and both
deploy scripts refuse chainId 5042 unless the mainnet minter, a governor and a guardian (or the
router, for `DeployForwarder`) are set explicitly. 14 new tests; full suite 246 passed. Because
these change contract bytecode, they apply to the next deployment only — the testnet contracts
keep the current behavior.

## 5. Blockers before mainnet (in order)

1. **Merge and review the hardening branch**, then an **independent review / audit** of
   `contracts/core` and `contracts/periphery` (see `docs/AUDIT_SCOPE.md`).
2. **Capped live test** on Arc mainnet: one small Gateway transfer into the new router, checked end to end.
3. **Governor multisig** and a **guardian** address chosen and exercised on testnet first.
4. **Pilot plan** with hard operational limits (finding 4) and a documented rollback.
5. **Network-aware web app** (finding 11), then flip `NETWORKS.arcMainnet` from `PENDING` after the deploy is verified.

## 6. Deploy runbook (to be run by the owner, never by an assistant)

Run from your own terminal; the keystore needs a TTY (see `CLAUDE.md`, gotcha 1). Re-check every
value against section 1 before running.

```bash
export ARC_RPC_URL="https://rpc.mainnet.arc.io"          # or your provider URL
cast chain-id --rpc-url "$ARC_RPC_URL"                    # must print 5042
cast code 0x2222222d7164433c4C09B0b0D809a9b52C04C205 --rpc-url "$ARC_RPC_URL"   # must be non-empty
export PORTAGE_USDC=0x3600000000000000000000000000000000000000
export PORTAGE_GATEWAY_MINTER=0x2222222d7164433c4C09B0b0D809a9b52C04C205
export PORTAGE_GOVERNOR=<multisig>                        # wiring is skipped; the multisig makes the calls
export PORTAGE_GUARDIAN=<guardian>

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$ARC_RPC_URL" --account <keystore-name> \
  --broadcast --skip-simulation --slow -vvvv
```

After deploy the multisig calls `ledger.setCreditor(router)`, `ledger.setDebitor(engine)`,
`router.setForwarder(forwarder)`, `registry.setGuardian(guardian)`; then re-verify wiring with the
`cast call` checks in `CLAUDE.md`, verify all five contracts on the explorer, and run the capped test.
