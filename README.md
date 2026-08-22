# Portage

Portage is cross-chain USDC payout consolidation infrastructure for Arc. Applications
receive USDC from users on many source chains (Base Sepolia and other Circle Gateway
domains), have those funds consolidated into a single per-app balance on Arc, and pay
out from that balance on demand. It is built on **Circle Gateway** — Circle's unified
USDC balance — rather than raw CCTP: a user's deposit becomes spendable Gateway balance,
and Portage mints and credits it atomically on Arc. This is the v0.1 deployment on Arc
Testnet.

## How it works

A payout clears in three stages:

1. **Deposit.** A user deposits USDC into the Circle Gateway unified balance on a source
   chain (e.g. Base Sepolia). They sign a burn intent with their own EOA; Portage never
   holds keys. The burn intent pins `destinationCaller` to the `PortageMintForwarder` and
   `destinationRecipient` to the `PortageRouter` on Arc, and carries a `PayoutMeta`
   binding (which app and account the deposit should credit).

2. **Consolidation.** On Arc, the `PortageMintForwarder` executes the mint and credit as
   a single atomic transaction. It validates the transfer, calls `gatewayMint` (which
   mints USDC to the Router and reverts unless the attestation is Circle-signed and the
   caller matches the intent's `destinationCaller`), and credits the Router by the exact
   minted amount. The primary path, `executeMintWithMeta`, carries the `PayoutMeta` as a
   separate argument bound to the transfer's `specHash` by an EIP-712 signature from the
   source depositor — the Circle Gateway testnet transfer API returns 500 on non-empty
   `hookData`, so the burn intent is submitted with empty `hookData` and the metadata is
   bound out of band but still tamper-evident. The Router decodes the authenticated
   metadata and forwards the funds into the Core `Ledger`, crediting
   `balances[appId][account]`. A deposit that cannot be attributed to a known app is held
   in quarantine for the governor to resolve — the Router never credits the wrong app.

3. **Payout.** The application calls `PayoutEngine.payout` (or `distribute` for a batch)
   against its own isolated Ledger balance. The engine verifies the caller is the app's
   registered `payoutController`, enforces per-`referenceId` idempotency, and asks the
   Ledger to debit and release USDC to the recipient. Payouts revert while the app is
   paused.

### Contracts

Immutable Core (`contracts/core/`):

- **AppRegistry** — identity and access control. Each integrated app has an `appId`, an
  `owner` (rotates the controller and can pause the app), and a `payoutController` (the
  only key allowed to trigger that app's payouts). Holds no funds. Its owner is the
  Portage governor, expected to be a multisig.
- **Ledger** — the USDC vault and per-app accounting core. Tracks
  `balances[appId][account]`. App isolation is structural: no function can move value
  from one app's namespace into another's. `credit` is called only by the creditor
  (Router) and pulls real USDC in; `debit` is called only by the debitor (PayoutEngine)
  and is blocked while an app is paused.
- **PayoutEngine** — on-demand payout authorization. Verifies the caller is the app's
  `payoutController`, enforces per-`referenceId` idempotency, and orchestrates the Ledger
  debit. Holds no funds and has no admin.

Periphery (`contracts/periphery/`):

- **PortageRouter** — the landing zone for Gateway mints on Arc. Forwards attributable
  deposits into the Ledger and quarantines unattributable ones. The only funds it holds
  at rest are quarantined amounts awaiting governor resolution.
- **PortageMintForwarder** — the atomic mint-and-credit composition primitive described
  above.

### The custody invariant

Every credited unit in the Ledger is a real USDC token held by the Ledger, and the
Ledger's total custody equals the sum of every app's balance:

```
custodyTotal == Σ appTotal        (and appTotal == Σ per-account balances)
```

Because `credit` pulls tokens in before crediting and `debit` decrements before releasing,
the system is solvent by construction: an app can never be credited value that is not
backed by a held token, and no app's payout can draw down another app's funds. These
properties are enforced in the test suite as invariants (see below).

## Deployment — Arc Testnet

All contracts are deployed on **Arc Testnet only** (chain ID `5042002`). Base Sepolia is
used solely as a source chain for USDC origin, not as a deployment target.

| Contract | Address |
|----------|---------|
| AppRegistry | `0xb803bF100F5CEb71dcC6Db20f8586A7A0901BB67` |
| Ledger | `0xEEc603760483B0689B76fb3780eE7edc2E1661b4` |
| PayoutEngine | `0xA9Ebe9fC146F6Bdb2FF5A688017eb496C56F66e0` |
| PortageRouter | `0x9eacb164e5B9D3D24b1A87437668B2245169eD4B` |
| PortageMintForwarder | `0x65473aF9a6006C20C100F6dBA174657b8D88aaed` |

Verifiable on the Arc Testnet explorer (Blockscout at `testnet.arcscan.app`):

- Ledger deployment:
  [`0x821a1b4a…`](https://testnet.arcscan.app/tx/0x821a1b4a4857872a8e23b00eabd63acec0c5c7a2fc6be2735851a45713ca969e)
- Live consolidation mint (`executeMintWithMeta`, Gateway → Arc):
  [`0x2a3f0411…`](https://testnet.arcscan.app/tx/0x2a3f04110f614c0b65938560e236583de48523ecacd05cbf595b14c244e7d056)

Network facts: RPC `https://rpc.testnet.arc.network/<KEY>`, Circle Gateway domain `26`,
gas paid in USDC, native USDC at `0x3600000000000000000000000000000000000000`.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/). OpenZeppelin is vendored as a git
submodule under `lib/`, so initialize submodules before building:

```bash
git submodule update --init --recursive
forge build
forge test
```

The suite has **81 tests**, all passing. That includes **12 invariant checks** across the
Ledger, PayoutEngine, and periphery — covering conservation (custody plus quarantine
equals minted), solvency, app isolation (`custodyTotal == Σ appTotal`,
`appTotal == Σ per-account`), and ledger/payment reconciliation. Invariant runs are
configured at 256 runs × 128 depth in `foundry.toml`.

```bash
forge test --summary   # per-suite pass/fail breakdown
```

## Deploy

Import the deployer key into a keystore once, then run the deploy script. This needs a
real interactive terminal for the keystore password prompt, so run it in your own shell:

```bash
cast wallet import deployer --interactive   # paste the deployer private key, set a password

export ARC_RPC_URL="https://rpc.testnet.arc.network/<KEY>"
# optional: PORTAGE_GOVERNOR (a multisig; if it differs from the deployer the script
# deploys but skips wiring and prints the calls the governor must make), PORTAGE_GUARDIAN

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$ARC_RPC_URL" \
  --account deployer \
  --broadcast --skip-simulation --slow -vvvv
```

`--skip-simulation` is required. Arc's native USDC lives at
`0x3600000000000000000000000000000000000000`, and the Router constructor calls
`forceApprove` on it. A local, forkless simulation has no token at that address and
reverts with `SafeERC20FailedOperation`; on Arc the token exists, so the broadcast
succeeds. A local dry-run reverting at that approve is expected, not a bug.

The script deploys the five contracts in dependency order and, when the deployer is the
governor, wires them: the Router as the Ledger's sole creditor, the PayoutEngine as its
sole debitor, and the Forwarder as the Router's authorized crediter.

## SDK

`@erhnysr/portage-sdk` (in `sdk/`) is a TypeScript SDK built on [viem](https://viem.sh). It is
**not published to npm** — use it from source or as a workspace dependency, building it
first:

```bash
cd sdk
npm install
npm run build   # tsc → dist/
```

It exposes two surfaces:

- **`PortageClient`** — a non-custodial client. Users sign burn intents with their own
  viem `walletClient`; the SDK never holds keys. Used to consolidate USDC from a source
  chain (e.g. Base Sepolia) into an app's balance on Arc.
- **`PortagePayouts`** — a server-side SDK for app backends. Authorizes payouts scoped to
  a single `appId`, signed by that app's `payoutController`.

Defaults target the Arc Testnet v0.1 deployment above. In v0.1 the `PayoutMeta` that
attributes a deposit to an app and account is delivered out of band and bound to the
transfer by an EIP-712 signature, as described under [How it works](#how-it-works).

## Repository layout

- `contracts/core/` — immutable Core: `AppRegistry`, `Ledger`, `PayoutEngine`.
- `contracts/periphery/` — `PortageRouter`, `PortageMintForwarder`.
- `contracts/lib/`, `contracts/interfaces/` — supporting libraries and interfaces.
- `script/` — deploy scripts.
- `test/` — unit, fuzz, and invariant tests.
- `sdk/` — TypeScript SDK.
- `web/` — landing page (Next.js).
- `docs/ARCHITECTURE.md` — design document, kept in sync with the contracts.
