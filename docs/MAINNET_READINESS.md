# Portage — Mainnet readiness

**Status (2026-10-14): NOT ready for mainnet.** Portage v0.1 runs on Arc Testnet only. The contracts
are unaudited and no mainnet deployment exists. This document lists what is verified, what is not,
and what must happen before real USDC is held.

## 1. Arc mainnet facts (from Circle's docs, not yet verified on-chain)

| Item | Value | Source |
|------|-------|--------|
| Chain ID | `5042` | docs.arc.io / references / connect-to-arc |
| Gas token | USDC (18 decimals native; ERC-20 interface uses 6) | same |
| RPC (primary) | `https://rpc.mainnet.arc.io` | same |
| Explorer | `https://explorer.arc.io` | same |
| CCTP / Gateway domain | `26` | docs.arc.io / references / contract-addresses |
| USDC (ERC-20 interface) | `0x3600000000000000000000000000000000000000` | same |
| Gateway Wallet | `0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE` | developers.circle.com / gateway / references / contract-addresses |
| Gateway Minter | `0x2222222d7164433c4C09B0b0D809a9b52C04C205` | same |
| Gateway API | `https://gateway-api.circle.com` | developers.circle.com / openapi / gateway.yaml (`servers`) |
| Source-chain USDC | Ethereum `0xA0b8…eB48` (dom 0), Avalanche `0xB97E…8a6E` (dom 1), Arbitrum `0xaf88…5831` (dom 3), Base `0x8335…2913` (dom 6) | developers.circle.com / stablecoins / usdc-contract-addresses |

These are exported from `sdk/src/config.ts` (`ARC_MAINNET_CHAIN`, `ARC_MAINNET_GATEWAY`,
`MAINNET_SOURCE_CHAINS`). `NETWORKS.arcMainnet` stays `PENDING` until Portage is deployed.

**Not verified:** nothing above was checked against the chain or the live Gateway API (the
environment that prepared this had no route to Arc mainnet RPC). Before any deploy, verify each
address yourself on the explorer, and confirm that the Gateway API accepts and attests a small
Arc-mainnet transfer. The explorer URL path format (`/tx/<hash>`, `/address/<addr>`) is assumed.

Also note: the testnet explorer in the SDK (`testnet.arcscan.app`) differs from the one currently
listed in the docs (`explorer.testnet.arc.io`). Check which one resolves before shipping links.

## 2. Findings from the code review (read-only; no tests were run for this review)

| # | Area | Finding | Where |
|---|------|---------|-------|
| 1 | Governor | Governor is the deployer EOA on testnet. All wiring and quarantine recovery are `onlyOwner`. Mainnet needs a multisig. Ownership uses `Ownable2Step`, so transfer is two-step. | `AppRegistry.sol:17`, `Ledger.sol:31`, `PortageRouter.sol:24`, `CLAUDE.md` (Deployed addresses) |
| 2 | Guardian | No guardian is set by default. The deploy script only sets one if `PORTAGE_GUARDIAN` is provided. Without it, only each app's owner can pause. | `Deploy.s.sol:69`, `AppRegistry.sol:68` |
| 3 | Kill switch | The only circuit breaker is per-app and halts outflows only (`Ledger.debit`). Deposits cannot be paused and there is no global pause. | `Ledger.sol:154`, `PortageRouter.sol:143-144` |
| 4 | Limits | No per-deposit or per-app caps exist. A pilot should be limited operationally (small amounts, one registered app). | `Ledger.sol:121-141` |
| 5 | Quarantine trust | The governor can send quarantined funds to any address (`withdrawQuarantine`) or credit them to any registered app. This is a trust assumption that must be documented for users. | `PortageRouter.sol:90`, `:103` |
| 6 | Deploy defaults | `Deploy.s.sol` defaults `PORTAGE_USDC` and `PORTAGE_GATEWAY_MINTER` to testnet values. A mainnet run must override the minter (`0x2222…C205`) explicitly, or it would wire the testnet minter. | `Deploy.s.sol:32-33`, `:46-47` |
| 7 | Replay / domain | The EIP-712 meta binding uses `chainId` and the forwarder address, so testnet signatures are not valid on mainnet. The SDK builds the domain from the selected network. | `PortageMintForwarder.sol:54`, `sdk/src/client.ts:198-202` |
| 8 | Atomicity | `executeMintWithMeta` is permissionless. It checks recipient == router, verifies the depositor's meta signature, then mints and credits in one transaction; `Router.credit` is idempotent per `specHash`. | `PortageMintForwarder.sol:67-89`, `PortageRouter.sol:127-147` |
| 9 | Web app | The demo app hardcodes testnet chain, explorer and RPC in several places. It needs a network-aware pass before any mainnet UI. | `web/lib/portage.ts`, `web/lib/shipments.ts`, `web/app/demo/chains.ts` |
| 10 | Tests | `CLAUDE.md` states 78 tests including invariants. They were not re-run for this review. Run `forge test` before relying on that number. | `CLAUDE.md` |

## 3. Blockers before mainnet (in order)

1. **Independent review / audit** of `contracts/core` and `contracts/periphery`. See `docs/AUDIT_SCOPE.md`.
2. **Verify Gateway on Arc mainnet** (on-chain code at both Gateway addresses, live API attests a test transfer).
3. **Governor multisig** and a **guardian** address chosen and tested on testnet first.
4. **Deploy-script guard**: require explicit mainnet addresses and a chain-id check before broadcasting.
5. **Pilot plan** with hard operational limits (see finding 4) and a documented rollback.
6. **Network-aware web app** (finding 9), then flip `NETWORKS.arcMainnet` from `PENDING` after the deploy is verified.

## 4. Deploy runbook (to be run by the owner, never by an assistant)

Run from your own terminal; the keystore needs a TTY (see `CLAUDE.md`, gotcha 1). Fill every value
from the verified table above; do not copy them from this file without re-checking.

```bash
export ARC_RPC_URL="https://rpc.mainnet.arc.io"          # or your provider URL
export PORTAGE_USDC=0x3600000000000000000000000000000000000000
export PORTAGE_GATEWAY_MINTER=0x2222222d7164433c4C09B0b0D809a9b52C04C205
export PORTAGE_GOVERNOR=<multisig>                        # wiring is skipped; the multisig must make the 3 calls
export PORTAGE_GUARDIAN=<guardian>

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$ARC_RPC_URL" --account <keystore-name> \
  --broadcast --skip-simulation --slow -vvvv
```

After deploy: governor calls `ledger.setCreditor(router)`, `ledger.setDebitor(engine)`,
`router.setForwarder(forwarder)`, `registry.setGuardian(guardian)`; then re-verify wiring with the
`cast call` checks in `CLAUDE.md`, verify all five contracts on the explorer, and run a capped pilot.
