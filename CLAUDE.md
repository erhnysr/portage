# Portage — Cross-chain USDC Payout Consolidator (Arc Testnet)

Cross-chain USDC consolidation infrastructure. Apps' funds flow from many chains (Base
Sepolia, etc.) into a single per-app balance on **Arc**, then pay out on demand. Built on
**Circle Gateway** (unified USDC balance) — raw CCTP intentionally not used in v0.1.

Design doc: `docs/ARCHITECTURE.md` (kept in sync with the contracts — update both together).

> NOTE: This file covers ONLY Portage. Other projects (Base/Basedrop, Republic validator,
> Coliseum) have their own CLAUDE.md files and are not mixed in here.

---

## Stack / layout

- Foundry, Solidity **0.8.28**, OpenZeppelin **5.1.0** (git submodule under `lib/`).
- `contracts/core/` — immutable Core: `AppRegistry`, `Ledger`, `PayoutEngine`.
- `contracts/periphery/` — `PortageRouter`, `PortageMintForwarder`.
- `contracts/lib/` — `AttestationDecoder`, `PayoutMetaLib`. `contracts/interfaces/` — `IGatewayMinter`.
- `script/Deploy.s.sol` — deploy + wire.
- `test/` — 78 tests (unit + fuzz invariants). Reference clone `arc-multichain-wallet/` is gitignored.

Build & test:
```bash
forge build
forge test            # 78 tests, incl. invariants (custody+quarantine==minted, isolation, solvency)
forge test --summary
```

---

## Arc Testnet — network facts (verified against docs.arc.io + gateway-api-testnet)

| Item | Value |
|------|-------|
| Chain ID | `5042002` (0x4cef52) |
| CCTP / Gateway domain | `26` |
| RPC | `https://rpc.testnet.arc.network/<KEY>` (public key rate-limits; get own key) |
| Explorer | `https://testnet.arcscan.app` (Blockscout; `/tx/<hash>`, `/address/<addr>`). NOTE: the old `explorer.arc.testnet.circle.com` no longer resolves (DNS). |
| Native gas token | USDC (gas paid in USDC on Arc) |
| USDC (native) | `0x3600000000000000000000000000000000000000` |
| GatewayMinter | `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` |
| GatewayWallet | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` |
| Gateway API (testnet) | `https://gateway-api-testnet.circle.com` |
| Faucet | `https://faucet.circle.com` |

Source-chain USDC (for consolidation origin): Base Sepolia `0x036CbD53842c5426634e7929541eC2318f3dCF7e` (domain 6).

---

## Deployed addresses (v0.1) — Arc Testnet (chainId 5042002)

Deployed & wired 2026-07-20. Governor = `0xD3467E00F6d7275C74e60fc7A1E5eD526893B29F` (deployer EOA).
Wiring verified on-chain: `Ledger.creditor==Router`, `Ledger.debitor==PayoutEngine`,
`Router.forwarder==MintForwarder`, and all immutable cross-refs (Ledger.usdc, Router.ledger,
PayoutEngine.ledger, Forwarder.router, Forwarder.gatewayMinter).

| Contract | Address |
|----------|---------|
| AppRegistry | `0xb803bF100F5CEb71dcC6Db20f8586A7A0901BB67` |
| Ledger | `0xEEc603760483B0689B76fb3780eE7edc2E1661b4` |
| PayoutEngine | `0xA9Ebe9fC146F6Bdb2FF5A688017eb496C56F66e0` |
| PortageRouter | `0x9eacb164e5B9D3D24b1A87437668B2245169eD4B` |
| PortageMintForwarder | `0x65473aF9a6006C20C100F6dBA174657b8D88aaed` |

> PortageMintForwarder was redeployed 2026-07-21 for the B1 change (`executeMintWithMeta` /
> `hashMetaBinding` / EIP712) via `script/DeployForwarder.s.sol`, which also rewired
> `router.setForwarder`. The original forwarder `0x07226E6163B3128b805774F73D26854a4de3661A`
> (executeMint-only, pre-B1) is dead. Core + Router unchanged.

Not yet done: no app registered (`registry.registerApp(...)`), no guardian set.

Re-verify wiring anytime:
```bash
cast call 0xEEc603760483B0689B76fb3780eE7edc2E1661b4 'creditor()(address)' --rpc-url "$ARC_RPC_URL"
cast call 0xEEc603760483B0689B76fb3780eE7edc2E1661b4 'debitor()(address)'  --rpc-url "$ARC_RPC_URL"
cast call 0x9eacb164e5B9D3D24b1A87437668B2245169eD4B 'forwarder()(address)' --rpc-url "$ARC_RPC_URL"
```

---

## Deploy — run in a SEPARATE terminal (see gotcha #1)

One-time keystore import (Coliseum method):
```bash
cast wallet import deployer --interactive   # paste the deployer private key, set a password
```

Env:
```bash
export ARC_RPC_URL="https://rpc.testnet.arc.network/<KEY>"
# optional overrides (defaults are the Arc addresses above; governor defaults to the deployer):
# export PORTAGE_GOVERNOR=0x...      # a multisig; if != deployer the script deploys but SKIPS wiring
# export PORTAGE_GUARDIAN=0x...
```

Deploy command:
```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$ARC_RPC_URL" \
  --account deployer \
  --broadcast --skip-simulation --slow -vvvv
```

`--skip-simulation` is REQUIRED: Arc's native USDC lives at `0x3600…0000`, and the Router
constructor calls `forceApprove` on it; a local/forkless simulation has no token there and
reverts with `SafeERC20FailedOperation`. On Arc the token exists, so the broadcast succeeds.
(A local `forge script` dry-run reverting at that approve is expected, not a bug.)

### Deploy order (the script does this automatically)
1. `AppRegistry(governor)`
2. `Ledger(governor, usdc, registry)`
3. `PayoutEngine(registry, ledger)`
4. `PortageRouter(governor, usdc, ledger, registry)`
5. `PortageMintForwarder(usdc, gatewayMinter, router)`

### Wiring (auto-run only when deployer == governor)
- `ledger.setCreditor(router)` — Router is the sole creditor
- `ledger.setDebitor(payoutEngine)` — PayoutEngine is the sole debitor
- `router.setForwarder(forwarder)` — only the Forwarder may credit the Router
- `registry.setGuardian(guardian)` — if `PORTAGE_GUARDIAN` set

If `PORTAGE_GOVERNOR` is a multisig different from the deployer, wiring is SKIPPED and the
script prints the three calls the governor must make itself.

### Post-deploy (per integrated app, e.g. Coliseum)
```
registry.registerApp(keccak256("coliseum"), appOwner, payoutController)
```

---

## Gotchas (learned on Coliseum — apply here too)

**1. TTY / deploy in a separate terminal.**
`forge script --broadcast` with a keystore (`--account`) needs a real interactive TTY for the
password prompt and does not run reliably inside the agent's tool shell. ALWAYS run the deploy
command yourself in a separate terminal. Claude prepares/edits the script but does not execute
the broadcast.

**2. 10,000-block log query limit — window your `eth_getLogs`.**
Arc RPC rejects `eth_getLogs` / event queries spanning more than ~10k blocks. When scanning for
events (e.g. `Credited`, `PaidOut`, `Quarantined`), page in <=10k-block windows:
```bash
# example: walk from FROM to LATEST in 10k chunks
cast logs --rpc-url "$ARC_RPC_URL" \
  --from-block <start> --to-block <start+9999> \
  --address <contract> "Credited(bytes32,bytes32,uint256,bytes32,uint8,bytes32)"
```
Never pass `--from-block 0 --to-block latest` in one shot — it errors on the window limit.

---

## Contract responsibilities (quick reference)

- **AppRegistry** — app identity/access: `owner`, `payoutController`, `paused`; governor onboards,
  guardian emergency-pauses. Pure state, no funds.
- **Ledger** — USDC vault. `balances[appId][account]`, `custodyTotal == Σ appTotal`. `credit`
  (onlyCreditor, pulls USDC, `transferId` idempotent), `debit` (onlyDebitor, CEI+nonReentrant,
  blocked when paused). Solvency by construction.
- **PayoutEngine** — on-demand `payout` / batch `distribute`, gated by app `payoutController`,
  `referenceId` replay-protected. Batch is whole-batch atomic (any failed debit reverts all).
- **PortageRouter** — mint landing zone; forwards valid deposits to the Ledger, quarantines
  malformed/unknown-app deposits (never mis-credits). No funds at rest except quarantine.
- **PortageMintForwarder** — atomic mint + credit; parses the Circle-signed attestation, calls
  `gatewayMint`, credits by measured balance delta. Burn intent pins `destinationCaller=forwarder`.

Gateway does NOT execute hookData on mint (verified against canonical source — ARCHITECTURE.md
§12); the forwarder is Portage's own atomic composition.
