# Portage — Architecture Design

> **Status:** v0.1 implemented, tested (78 tests), and **deployed + wired on Arc Testnet 2026-07-20** (addresses in CLAUDE.md → "Deployed addresses").
> **Chain:** Arc Testnet (chainId `5042002`, CCTP domain `26`) as settlement hub
> **Protocol:** Circle Gateway (unified USDC balance) — raw CCTP intentionally not used in v0.1
> **Custody:** Non-custodial — end users / app treasuries sign with their own EOAs

---

## 1. What Portage Is

Portage is **cross-chain USDC payout consolidation infrastructure** for applications.

Money flows from many chains (Base Sepolia, later Ethereum/Arbitrum Sepolia) into a **single settlement balance on Arc**, partitioned per integrated application. Applications (marketplace, escrow, reward pool, arena) then trigger **payouts on demand** against their own isolated balance.

Two verbs, one hub:

- **Consolidate** — pull USDC from any supported chain into an app's ledger account on Arc.
- **Pay out** — release USDC from that ledger account to a recipient, on demand, with app-defined metadata attached.

Circle Gateway does the actual cross-chain USDC movement (burn intent → attestation → mint). Portage adds the layer Gateway does not provide: **per-app accounting, isolation, metadata-driven settlement, and a payout engine.**

### Design principles

1. **Non-custodial.** Portage contracts never hold a private key that controls user funds. Every value-moving action is authorized by an EOA signature (user, app treasury, or app payout controller). The relayer is a **liveness** component, never a **safety** one.
2. **Core/periphery split (Uniswap v4 style).** `PortageCore` (Ledger + PayoutEngine) is minimal and immutable. Everything mutable/experimental lives in swappable periphery (Router, Hooks) and adapters.
3. **App isolation.** One app's balance, bug, or pause can never touch another app's funds. Enforced by namespaced storage + per-app access control + global invariants.
4. **Adapter pattern.** `GatewayAdapter` is the only adapter in v0.1, but the `IConsolidationAdapter` interface leaves room for a future `CctpAdapter`, `LiFiAdapter`, etc.
5. **Metadata is first-class.** Gateway's signed `hookData` field carries structured payout intent (`appId`, `referenceId`, `action`) end-to-end. Because `hookData` is part of the Circle-signed `TransferSpec`, it cannot be tampered with in flight.

---

## 2. Component Diagram (ASCII)

```
                         SOURCE CHAIN (e.g. Base Sepolia, domain 6)
  ┌───────────────────────────────────────────────────────────────────────┐
  │  End user / App treasury EOA                                            │
  │        │  (1) approve + deposit USDC (own tx, non-custodial)            │
  │        ▼                                                                │
  │  Circle GatewayWallet  0x0077...19B9   ── unified balance (off-chain) ──┼──┐
  └───────────────────────────────────────────────────────────────────────┘  │
        │  (2) sign BurnIntent (client-side, wagmi/viem signTypedData)        │
        │      destinationRecipient = PortageRouter@Arc                       │
        │      hookData = PayoutMeta{appId, referenceId, action, account}     │
        ▼                                                                     │
  ┌──────────────────────┐   (3) POST /v1/transfer      ┌───────────────────▼─┐
  │  Portage SDK (client)│ ───────────────────────────▶ │  Circle Gateway API │
  └──────────────────────┘   ◀── attestation+signature  └─────────┬───────────┘
        │                                                          │
        │ (4) hand attestation to Relayer (or self-submit)         │
        ▼                                                          │
  ┌──────────────────────┐                                         │
  │  Portage Relayer      │  (5) gas pre-flight on Arc (mandatory) │
  │  (liveness only)      │  (6) Forwarder.executeMintWithMeta ────┐│
  │                       │      (att, sig, meta, metaSig)         ││
  └──────────────────────┘                                        ││
                                                                   ││
             ▼               ARC TESTNET (domain 26) — SETTLEMENT HUB
  ┌──────────────────────────────────────────────────────────────────────────┐
  │  ╔════════════════════ PERIPHERY (upgradeable) ════════════════════════╗  │
  │  ║  PortageMintForwarder   (ONE atomic tx — this is Portage's "hook")  ║  │
  │  ║    a) decode TransferSpec from attestation → recipient, value,      ║  │
  │  ║       hookData (authentic: gatewayMint reverts if att not Circle-   ║  │
  │  ║       signed)                                                       ║  │
  │  ║    b) GatewayMinter.gatewayMint(att, sig) ─┐                        ║  │
  │  ║    c) PortageRouter.credit(...)            │                        ║  │
  │  ╚════════════════════════════════════════════╪═══════════════════════╝  │
  │        │ destinationCaller = Forwarder (only  │ it may mint → anti-frontrun)│
  │        ▼                                       ▼                           │
  │  Circle GatewayMinter 0x0022...475B   →  mints USDC to PortageRouter        │
  │        │ (plain ERC20 mint to destinationRecipient; hookData NOT executed) │
  │        ▼                                                                   │
  │  ╔══════════ PortageRouter (mint landing zone, holds no funds at rest) ═╗  │
  │  ║  credit(appId, account, mintedValue, specHash) — decoded hookData    ║  │
  │  ╚══════════════════════════════╤═════════════════════════════════════╝  │
  │                                 │ credit(appId, account, amount, specHash) │
  │  ╔══════════════ PortageCore (MINIMAL, IMMUTABLE) ═════════════════════╗  │
  │  ║  ┌──────────────┐   ┌──────────────────┐   ┌───────────────────┐   ║  │
  │  ║  │  AppRegistry │   │     Ledger       │   │   PayoutEngine    │   ║  │
  │  ║  │  who owns    │   │ balances[app]    │   │ debit + transfer  │   ║  │
  │  ║  │  each app    │◀──│ [account]        │◀──│ (CEI, nonReentrant)│  ║  │
  │  ║  └──────────────┘   └──────────────────┘   └─────────┬─────────┘   ║  │
  │  ╚═══════════════════════════════════════════════════════╪═══════════╝  │
  │                                                            │ (payout)     │
  │  ╔═══════════ ADAPTERS (IConsolidationAdapter) ═══════════╪═══════════╗  │
  │  ║   GatewayAdapter (v0.1)   [ future: CctpAdapter, ... ] │           ║  │
  │  ║   used for OUTBOUND cross-chain payouts (v0.2+)        ▼           ║  │
  │  ╚═══════════════════════════════════════════════════════════════════╝  │
  │                                 │ same-chain payout: USDC → recipient EOA │
  └─────────────────────────────────┼──────────────────────────────────────┘
                                     ▼
                            Recipient EOA on Arc
                     (v0.1: on-Arc payout; v0.2: cross-chain out)

  ┌─────────────────────────── APP BACKEND (e.g. Coliseum) ──────────────────┐
  │  Portage Server SDK → PayoutEngine.distribute(appId, referenceId, ...)    │
  │  authorized by app payoutController key (per-app)                         │
  └──────────────────────────────────────────────────────────────────────────┘
```

**Trust boundary summary:** solid lines carry value; every value edge is gated by either a Circle-signed attestation or an EOA signature. The Relayer sits only on edges (5)–(6): it can *delay* but cannot *redirect* funds — `destinationRecipient` and `hookData` are fixed inside the signed burn intent, and the ledger credit is derived from the **on-chain minted amount**, not from anything the relayer supplies.

---

## 3. Contracts — Responsibilities & Function Signatures

Signatures are **design intent** (interfaces), not implementation. USDC is 6-decimal; all amounts are atomic units (`uint256`).

### 3.1 PortageCore (immutable, no proxy)

Deployed once, never upgraded. No `delegatecall`, no admin that can move funds. Admin surface limited to registry management and pause guardianship. Splitting into three logical modules; may be one contract or three linked immutables.

#### AppRegistry — who owns each app

```solidity
struct AppConfig {
    bool    exists;            // registration flag
    bool    paused;            // app-level circuit breaker (isolated)
    address owner;             // can rotate controller, pause the app
    address payoutController;  // the only key allowed to trigger payouts for this app
}

function registerApp(bytes32 appId, address owner, address payoutController) external;   // onlyGovernor
function setPayoutController(bytes32 appId, address newController) external;              // onlyAppOwner(appId)
function transferAppOwnership(bytes32 appId, address newOwner) external;                  // onlyAppOwner(appId)
function setAppPaused(bytes32 appId, bool paused) external;                               // onlyAppOwner or onlyGuardian
function setGuardian(address guardian) external;                                          // onlyGovernor
function appConfig(bytes32 appId) external view returns (AppConfig memory);
```

> **Implementation note (deliberate deviation from the original draft).** Lifetime accounting counters (`totalCredited` / `totalPaid`) were **moved out of `AppConfig` and into the `Ledger`**, co-located with the balances they derive from. This keeps `AppRegistry` as pure identity/access state and avoids a Registry↔Ledger write-coupling (the Ledger would otherwise have to call back into the Registry on every credit/debit). The `AppConfig.exists` flag replaces the implicit "registered" check. This is within the doc's stated allowance that the three Core modules "may be one contract or three linked immutables."

#### Ledger — namespaced per-app balances (isolation core)

```solidity
// balances[appId][account] — account is an app-defined bytes32 sub-account
//   (e.g. a specific arena, an escrow id, a user handle). App isolation lives here:
//   no function can move value from balances[appA][*] into balances[appB][*].
mapping(bytes32 => mapping(bytes32 => uint256)) private balances;
mapping(bytes32 => uint256) private appTotal;        // Σ accounts within an app
uint256 private custodyTotal;                         // Σ appTotal, must == USDC.balanceOf(Core) held for apps

// Only PortageRouter (registered) may credit; only PayoutEngine may debit.
function credit(bytes32 appId, bytes32 account, uint256 amount, bytes32 transferId) external; // onlyRouter
function debit (bytes32 appId, bytes32 account, uint256 amount, address to) external;          // onlyPayoutEngine (pushes USDC to `to`)

function balanceOf(bytes32 appId, bytes32 account) external view returns (uint256);
function appBalance(bytes32 appId) external view returns (uint256);
```

**Invariant (maintained by construction):** `custodyTotal == Σ appTotal[app]` and `appTotal[app] == Σ balances[app][account]`. `credit` and `debit` update the per-account balance, its `appTotal`, and `custodyTotal` in lockstep, so the equalities hold after every mutation without an explicit runtime check. They are verified continuously by the Foundry fuzz invariant tests (§7). This is the mathematical guarantee of app isolation.

#### PayoutEngine — debit + release (on demand)

```solidity
// Same-chain (Arc) payout, v0.1
function payout(
    bytes32 appId,
    bytes32 account,
    bytes32 referenceId,     // idempotency key (app's order/round id)
    address recipient,
    uint256 amount
) external;                  // onlyPayoutController(appId), nonReentrant

// Batch (arena reward distribution) — one debit loop, atomic
function distribute(
    bytes32 appId,
    bytes32 account,
    bytes32 referenceId,
    address[] calldata recipients,
    uint256[] calldata amounts
) external;                  // onlyPayoutController(appId), nonReentrant

// Cross-chain outbound payout (v0.2+, via adapter)
function payoutCrossChain(
    bytes32 appId, bytes32 account, bytes32 referenceId,
    address recipient, uint256 amount, uint32 destinationDomain
) external;                  // routes through IConsolidationAdapter
```

Order of operations is strict **Checks-Effects-Interactions**: verify controller → check balance → `debit` (effect) → `USDC.transfer` (interaction). `referenceId` is recorded to reject replays.

### 3.2 Periphery (upgradeable / replaceable)

> **Confirmed by canonical source (see §12):** Circle's `GatewayMinter.gatewayMint` does **not** execute `hookData` — it only mints USDC to `destinationRecipient` and emits `AttestationUsed`. On-chain composition is therefore something Portage builds itself. The pattern below wraps the mint in a Portage-owned forwarder so mint + ledger credit happen **atomically in one transaction**, with authenticity inherited from `gatewayMint` (which reverts unless the attestation is Circle-signed).

#### PortageMintForwarder — atomic mint + credit ("Portage's hook")

```solidity
// Single entrypoint the Relayer calls. Everything below is one atomic tx.
function executeMint(bytes calldata attestationPayload, bytes calldata signature) external { // onlyRelayer (or open)
    // 1. Decode the TransferSpec straight from the attestation bytes.
    //    hookData/recipient/value are AUTHENTIC because step 2 reverts if the
    //    attestation is not signed by Circle's attestationSigner.
    (address recipient, uint256 value, bytes memory hookData, bytes32 specHash) = _parse(attestationPayload);
    require(recipient == address(portageRouter), "recipient != Router");

    // 2. Mint USDC to the Router (plain ERC20 mint; reverts on bad/expired/replayed attestation).
    gatewayMinter.gatewayMint(attestationPayload, signature);

    // 3. Credit the ledger with the exact minted value, keyed by the on-chain specHash.
    portageRouter.credit(hookData, value, specHash);
}
```

Burn intent is built with `destinationRecipient = PortageRouter` **and** `destinationCaller = PortageMintForwarder` — Circle's minter enforces `destinationCaller == msg.sender` (Mints.sol:296), so **only the forwarder can execute the mint**. This closes the front-run / orphaned-mint gap: nobody can call `gatewayMint` directly to dump USDC on the Router without crediting it.

#### PortageRouter — the mint landing zone (holds no funds at rest)

```solidity
// Only the forwarder may credit. mintedValue is the value from the same signed
// spec that was just minted; specHash is the on-chain replay key.
function credit(bytes calldata hookData, uint256 mintedValue, bytes32 specHash) external; // onlyForwarder
```

`hookData` decodes to `PayoutMeta` (see §4). Credited amount = the `value` field of the just-minted attestation (equivalently the Router's USDC balance delta), never a relayer-supplied number. Router forwards the USDC into Core and calls `Ledger.credit(appId, account, mintedValue, specHash)`.

### 3.3 Adapters (IConsolidationAdapter) — NOT BUILT (deferred to v0.2+)

> **Status: design sketch, not in the v0.1 codebase.** No `IConsolidationAdapter`, `GatewayAdapter`,
> or `initiateOutbound` exists in `contracts/`. v0.1 inbound consolidation is handled directly by
> `PortageMintForwarder` + `PortageRouter` (§3.2), with no adapter indirection. The interface below is
> retained as the intended abstraction for outbound cross-chain payouts, which land in v0.2+ (see §10
> out-of-scope).

```solidity
interface IConsolidationAdapter {
    // Build/submit an outbound cross-chain transfer of USDC held by Core.
    function initiateOutbound(
        uint32 destinationDomain,
        address recipient,
        uint256 amount,
        bytes calldata extra
    ) external returns (bytes32 transferId);

    function protocolId() external pure returns (bytes32);  // "GATEWAY", future: "CCTP_V2"
}
```

Once built, `GatewayAdapter` would wrap deposit-to-GatewayWallet + burn-intent submission for outbound payouts, letting new protocols slot in without touching Core.

### 3.4 External (not ours) — Circle contracts, same address cross-chain

| Contract | Address (all chains) | Role |
|---|---|---|
| GatewayWallet | `0x0077777d7EBA4688BDeF3E311b846F25870A19B9` | deposit / unified balance / withdraw |
| GatewayMinter | `0x0022222ABE238Cc2C7Bb1f21003F0a260052475B` | `gatewayMint(attestation, signature)` |
| Gateway API | `https://gateway-api-testnet.circle.com` | `/v1/info`, `/v1/balances`, `/v1/transfer`, `/v1/transfers/{id}` |
| USDC (Arc) | `0x3600000000000000000000000000000000000000` | native gas token on Arc |
| USDC (Base Sepolia) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | |

---

## 4. hookData / PayoutMeta Schema

`hookData` travels inside the Circle-signed `TransferSpec`, so it is **tamper-evident**. Portage defines a versioned ABI encoding:

```
PayoutMeta v1 (abi.encode):
┌────────────┬──────────┬────────────────────────────────────────────────────┐
│ field      │ type     │ meaning                                             │
├────────────┼──────────┼────────────────────────────────────────────────────┤
│ schema     │ uint8    │ =1, version tag (forward compat)                    │
│ appId      │ bytes32  │ which app's ledger to credit (e.g. keccak("coliseum"))│
│ account    │ bytes32  │ sub-account within app (e.g. arenaId)               │
│ action     │ uint8    │ enum: 0=CREDIT, 1=ENTRY_FEE, 2=ESCROW_FUND, 3=TOPUP │
│ referenceId│ bytes32  │ app-side id for idempotency / reconciliation        │
│ payer      │ bytes32  │ original depositor (audit trail)                    │
└────────────┴──────────┴────────────────────────────────────────────────────┘
```

Router decodes → validates `appId` is registered and not paused → credits `balances[appId][account]`. Unknown `schema` or unregistered `appId` ⇒ funds routed to a **quarantine account** for that app (recoverable by governor), never lost, never mis-credited.

**Coliseum example:** a Base Sepolia player pays a 5 USDC arena entry.
`PayoutMeta{ schema:1, appId:keccak("coliseum"), account:arenaId, action:ENTRY_FEE, referenceId:playerEntryId, payer:playerAddr }`.

---

## 5. Flow Diagrams

### 5.1 Consolidation (deposit in) — Base Sepolia → Arc

```
User EOA (Base Sepolia)          Portage SDK           Gateway API        Relayer         Arc contracts
      │                              │                     │                 │                  │
 (1)  │ approve(GatewayWallet,amt)   │                     │                 │                  │
      │ deposit(USDC,amt)  ──────────┼──▶ [GatewayWallet, Base Sepolia]      │                  │
      │                              │                     │                 │                  │
 (2)  │ signTypedData(BurnIntent)    │                     │                 │                  │
      │   dstRecipient=Router@Arc    │                     │                 │                  │
      │   hookData=PayoutMeta ───────┼─▶ buildIntent       │                 │                  │
 (3)  │                              │ POST /v1/transfer ─▶│                 │                  │
      │                              │◀── attestation+sig ─│                 │                  │
 (4)  │                              │ handoff ────────────┼───────────────▶ │                  │
 (5)  │                              │                     │   gas pre-flight (Arc, gas=USDC) ──▶│ check
 (6)  │                              │                     │   Forwarder.executeMintWithMeta ───▶│ PortageMintForwarder
      │                              │                     │   (att, sig, meta, metaSig)     │     ├ recover(metaSig)==sourceDepositor
      │                              │                     │                 │     ├ gatewayMint → USDC minted to Router
      │                              │                     │                 │     └ Router.credit(encode(meta),value,specHash)
 (7)  │                              │                     │                 │   Ledger: balances[app][account] += value
      │                              │                     │                 │   invariant check ✓        (all one atomic tx)
```

> In v0.1 the burn intent carries **empty hookData** and PayoutMeta is delivered as the separate
> `meta`+`metaSig` arguments above, bound to `specHash` and signed by the depositor (§13). The
> `hookData`-carried variant (`executeMint`) is retained for forward-compatibility.

Key safety notes: (a) gas pre-flight (5) is a **mandatory** step — if the Arc mint would fail for gas, do not proceed; the attestation persists and can be minted later, so no funds are stranded. (b) `specHash` (the `keccak256` of the `TransferSpec`, recorded on-chain by `gatewayMint` itself for replay protection — Mints.sol:335) makes credit idempotent: a double-submit reverts inside `gatewayMint` before reaching `credit`. (c) Step (6) is a **single atomic transaction** — either USDC is minted *and* the ledger is credited, or neither happens.

### 5.2 Payout (out, on demand) — on Arc (v0.1)

```
App backend (Coliseum)      Portage Server SDK       PayoutEngine (Arc)        Ledger
      │                          │                        │                      │
 (1)  │ arena ends, winners set  │                        │                      │
      │ requestPayout(...) ──────▶ sign w/ payoutController│                      │
 (2)  │                          │ distribute(appId,       │                      │
      │                          │   account, refId,       │                      │
      │                          │   recipients[], amts[])─▶ onlyController ✓     │
 (3)  │                          │                        │ refId not seen ✓ (replay guard)
 (4)  │                          │                        │ debit each ───────────▶ balances[app][acct]-=Σ
      │                          │                        │   invariant ✓         │
 (5)  │                          │                        │ USDC.transfer→winners │ (CEI, nonReentrant)
 (6)  │                          │                        │ emit PayoutSettled    │
```

App isolation in action: `distribute` can only debit `balances[coliseum][arenaId]`. Even a compromised Coliseum controller key cannot reach another app's funds — the `appId` is bound to the authorizing controller in `AppRegistry`.

### 5.3 Cross-chain payout (out) — Arc → Base Sepolia (v0.2+, sketch)

```
PayoutEngine → debit ledger → GatewayAdapter.initiateOutbound(destDomain=6, recipient, amt)
   → deposit Core USDC to GatewayWallet@Arc → sign burn intent (Core as depositor via session key / EOA treasury)
   → Gateway API attestation → gas pre-flight on Base → gatewayMint@Base → recipient receives USDC on Base.
```
(Deferred; requires Core-controlled outbound signing design — see §8 out-of-scope.)

---

## 6. Storage Layout Summary

Status legend: **[built]** = implemented + tested in v0.1 Core; **[periphery]** = deferred to the Router/Forwarder layer (not in the Core contracts yet).

| Contract | Key storage | Purpose | Isolation role | Status |
|---|---|---|---|---|
| AppRegistry | `mapping(bytes32 appId => AppConfig{exists,paused,owner,payoutController})` + `address guardian` | identity, ownership, controller, pause | binds appId ↔ authorized keys | **[built]** |
| Ledger | `mapping(bytes32 appId => mapping(bytes32 account => uint256))` | per-app, per-account balances | **primary isolation boundary** | **[built]** |
| Ledger | `mapping(bytes32 appId => uint256) appTotal` + `uint256 custodyTotal` | invariant accounting | detects cross-app leakage | **[built]** |
| Ledger | `mapping(bytes32 appId => uint256) totalCredited` + `totalPaid` | lifetime reconciliation counters (moved here from `AppConfig`) | per-app, audit-only | **[built]** |
| Ledger | `mapping(bytes32 transferId => bool) creditProcessed` | inbound idempotency (credit-once per Gateway spec hash) | prevents double-credit | **[built]** |
| PayoutEngine | `mapping(bytes32 appId => mapping(bytes32 referenceId => bool)) settled` | outbound idempotency | prevents double-pay / replay | **[built]** |
| Router | `mapping(bytes32 specHash => uint256) quarantined` + `uint256 quarantinedTotal` | unmatched/malformed deposits held pending governor recovery | recoverable, never mis-credited | **[built]** |

All app-scoped maps are keyed by `appId` first — there is no global mutable balance that any single app can touch.

> **Sync note:** inbound credit idempotency is implemented in the **Ledger** (`creditProcessed`), not in the Router as the original draft suggested. The Router carries no `processed` map — credit-once at the mint landing zone is provided by `gatewayMint`'s own `specHash` replay guard (a resubmit reverts before `credit` is reached), with the Ledger's `creditProcessed` as the independent second guard (see threat T1). The `quarantine` map is a Router/periphery responsibility (see §4) and is intentionally **not** in the Core `AppRegistry`; the Core `Ledger.credit` simply reverts (`AppNotRegistered`) for unknown apps, and the Router routes those (plus malformed-hookData deposits) to quarantine instead of ever calling `credit` — so the atomic mint still completes and funds are captured, never mis-credited or stranded.

---

## 7. Security Model

### Threat list → mitigations

| # | Threat | Mitigation |
|---|---|---|
| T1 | **Replay / double-credit** of an attestation (resubmit mint) | Two independent guards: (a) `gatewayMint` marks the `specHash` used and reverts a resubmit (Mints.sol:335) *before* control ever reaches `credit`; (b) the Ledger records each `transferId` in `creditProcessed` and rejects a second credit for the same spec. Credit therefore happens at most once even if the mint path were somehow re-entered |
| T2 | **Inflated credit** via forged/oversized hookData amount | Credit uses the `value` from the just-minted signed spec (= Router balance delta), never a relayer-supplied number |
| T3 | **hookData tampering** in flight | hookData is inside the Circle-signed `TransferSpec` and is folded into `specHash` (TransferSpecLib.sol:481); any edit invalidates the attestation signature and reverts `gatewayMint` |
| T4 | **Orphaned mint / front-run** (someone calls `gatewayMint` directly, USDC lands on Router uncredited) | Burn intent sets `destinationCaller = PortageMintForwarder`; Circle's minter enforces `destinationCaller == msg.sender` (Mints.sol:296), so only the forwarder can mint — and it credits atomically. Degraded `settle` path stays idempotent on `specHash` |
| T5 | **Cross-app fund drain** | Ledger namespacing by `appId` + `custodyTotal == Σ appTotal` invariant revert |
| T6 | **Unauthorized payout** | `onlyPayoutController(appId)`; controller bound in AppRegistry; per-app, not global |
| T7 | **Payout replay / double-pay** | `settled[appId][referenceId]` one-shot |
| T8 | **Reentrancy on USDC transfer** | strict CEI ordering + `nonReentrant`; debit before transfer |
| T9 | **Burned-but-not-minted (stranded funds)** | mandatory gas pre-flight; attestation is persistent → mint retriable; relayer idempotent |
| T10 | **Relayer compromise** | relayer is liveness-only: cannot change `destinationRecipient`/`hookData` (signed) nor fabricate credits (balance-delta). Worst case = delayed settlement |
| T11 | **Malicious/compromised app owner** | blast radius limited to that app's own balance; global funds unaffected; guardian can pause the single app |
| T12 | **USDC blacklist/freeze** (Circle can freeze addresses) | payout transfers handle failure without corrupting ledger (debit reverts atomically with failed transfer) |
| T13 | **Governance key abuse** | Core is immutable (no fund-moving admin); registry governor is multisig; guardian can only pause, not withdraw |
| T14 | **Rounding / fee mismatch** | Gateway `maxFee` is deducted from transfer; credited = minted delta, so fee never over-credits app |
| T15 | **DoS via unregistered appId spam** | unmatched deposits go to per-app quarantine, bounded; no unbounded loops in hot path |

### Trust assumptions (explicit)

- **Circle Gateway** is trusted for correct attestation and cross-chain USDC integrity. Portage inherits Gateway's security for the movement leg.
- **Arc L1** liveness/finality (sub-second) is trusted for the settlement hub.
- **Relayer** is trusted for liveness only, never for safety.
- **App payout controllers** are trusted **only within their own app's balance** — never globally.

### Invariants (must hold at all times)

Maintained by construction in the Ledger/Router and verified continuously by Foundry fuzz invariant
tests (256 runs × 128 depth). The test function enforcing each one is named in parentheses.

1. `USDC.balanceOf(Core) >= custodyTotal` — Core is always solvent for what it owes apps (`invariant_solvency`).
2. `custodyTotal == Σ_app appTotal[app]` (`invariant_custodyEqualsSumOfApps`).
3. `appTotal[app] == Σ_account balances[app][account]` (`invariant_appTotalEqualsSumOfAccounts`, `invariant_perAccountMatchesGhost`).
4. No state transition moves value from `balances[appA]` to `balances[appB]`.
5. Conservation across the periphery: `custodyTotal + quarantinedTotal == Σ minted` — every minted USDC unit is either credited to an app or held in quarantine, never lost or double-counted (`invariant_conservation`).
6. Router holds no attributable funds at rest: its USDC balance equals `quarantinedTotal` (`invariant_custodyAndRouterBalances`).
7. Lifetime counters reconcile: per-app `totalCredited` / `totalPaid` stay consistent with the balances they derive from (`invariant_lifetimeCountersReconcile`).
8. Payments reconcile: the total debited from the Ledger equals the total released to payout recipients (`invariant_paymentsReconcile`).

---

## 8. SDK Interface Draft

Two surfaces: **client SDK** (browser, non-custodial signing) and **server SDK** (app backend, payout authorization).

### Client SDK (wagmi/viem)

```ts
const portage = new PortageClient({
  arc: { chainId: 5042002, core: "0x…Core", router: "0x…Router" },
  gatewayApi: "https://gateway-api-testnet.circle.com",
  sourceChains: ["baseSepolia"],           // v0.1
});

// 1. Deposit into Circle Gateway on the source chain (user's own tx)
await portage.deposit({ chain: "baseSepolia", amount: "5.0" });   // approve + deposit

// 2. Build a consolidation intent (returns EIP-712 typed data to sign)
const intent = portage.buildConsolidationIntent({
  sourceChain: "baseSepolia",
  amount: "5.0",
  meta: { appId: "coliseum", account: arenaId, action: "ENTRY_FEE", referenceId: entryId },
});
const signature = await walletClient.signTypedData(intent.typedData);   // user EOA

// 3. Submit → attestation → hand to relayer (or self-mint)
const { transferId } = await portage.submitConsolidation(intent, signature);

// reads
await portage.getUnifiedBalance(userAddress);          // Gateway /v1/balances aggregation
await portage.getAppBalance("coliseum", arenaId);      // Ledger.balanceOf
portage.on("Credited", (e) => { /* appId, account, amount, transferId */ });
```

### Server SDK (app backend, payout authorization)

```ts
const engine = new PortagePayouts({
  arc: { core: "0x…Core" },
  appId: "coliseum",
  signer: coliseumPayoutControllerSigner,   // per-app key, NOT a global key
});

await engine.payout({ account: arenaId, referenceId: roundId, recipient, amount: "12.0" });
await engine.distribute({ account: arenaId, referenceId: roundId, recipients, amounts });
```

The server SDK never touches user funds — it only signs payout authorizations scoped to `appId`. Gas pre-flight is executed automatically before any mint the SDK submits.

---

## 9. First Showcase Integration — Coliseum

**Scenario:** players join an Arc arena by paying a USDC entry fee from Base Sepolia; winners are paid out on Arc when the arena ends.

```
Entry (consolidation):
  player (Base Sepolia) → deposit 5 USDC to GatewayWallet
    → sign burn intent, dstRecipient=Router@Arc,
       hookData=PayoutMeta{coliseum, arenaId, ENTRY_FEE, entryId, player}
    → attestation → gatewayMint@Arc → Ledger: balances[coliseum][arenaId] += 5

Arena resolves:
  Coliseum backend → PayoutEngine.distribute(
      appId=coliseum, account=arenaId, referenceId=resultId,
      recipients=[winner1, winner2], amounts=[…])
    → debits balances[coliseum][arenaId], transfers USDC on Arc to winners
```

Coliseum is registered once via `AppRegistry.registerApp(keccak("coliseum"), owner, payoutController)`. Its balance is fully isolated from Portage's other integrations (Basedrop, tipping.base, etc. if later onboarded).

---

## 10. MVP Scope — v0.1

### In scope (v0.1)

- Arc Testnet deployment of `PortageCore` (AppRegistry + Ledger + PayoutEngine) + `PortageRouter` + `PortageMintForwarder`.
- **Inbound:** Base Sepolia → Arc consolidation driven directly by `PortageMintForwarder` + `PortageRouter` (no adapter layer), with `PayoutMeta` v1.
- **Outbound:** same-chain (Arc) payouts + batch `distribute`.
- Non-custodial client signing (wagmi/viem EIP-712 burn intents).
- Mandatory gas pre-flight on Arc before mint.
- Portage Relayer (liveness-only mint submission) with idempotency.
- App isolation: namespaced ledger + invariants + per-app pause.
- TypeScript SDK (client + server) with the interfaces in §8.
- **Coliseum** end-to-end integration as the showcase.
- Basic reconciliation/read API (unified balance, app balance, event stream).

### Out of scope (deferred)

- **The `IConsolidationAdapter` / `GatewayAdapter` abstraction** (§3.3) — not built in v0.1; inbound is handled directly by the Forwarder + Router. The adapter layer arrives with outbound cross-chain payouts.
- **Cross-chain outbound payouts** (Arc → Base/other). Requires Core-controlled outbound signing design.
- Additional source chains beyond Base Sepolia (Ethereum/Arbitrum Sepolia are easy adds — same domain model — but not in v0.1 test matrix).
- **Raw CCTP adapter** (`CctpAdapter`) — interface reserved, not built.
- Gas sponsorship / paymaster (users/relayer pay their own gas in v0.1).
- CCTP Fast Transfer optimizations (Arc is already instant; inbound-fast is a later tuning).
- Mainnet deployment (needs Gateway mainnet access review — possible whitelist).
- Dispute windows / time-locked escrow semantics beyond simple hold+release.
- Non-EVM source chains (Solana Gateway domain exists but out of scope).
- Contract upgradeability for Core (intentionally immutable; periphery is the upgrade path).

### v0.1 exit criteria

1. A Base Sepolia deposit lands as a correct, isolated credit in `balances[coliseum][arenaId]` on Arc.
2. `distribute` pays multiple winners on Arc, debiting only Coliseum's balance, with replay protection.
3. All invariants (§7) hold across a full deposit→payout cycle under test.
4. Relayer failure/restart never double-credits or double-pays (idempotency proven).

---

## 11. Open Questions to Resolve Before Build

1. ~~**Does Gateway auto-execute hooks on Arc mint**, or must the Relayer call `Router.settle()` after a plain mint?~~ **RESOLVED (see §12).** Gateway does **not** execute hooks. `gatewayMint` only mints USDC to `destinationRecipient`. Primary path is the **atomic `PortageMintForwarder`** (mint + credit in one tx), with a `destinationCaller`-pinned burn intent; relayer is liveness-only. No live funded test required — answered from canonical contract source.
2. **Outbound depositor identity** for cross-chain payouts (v0.2) — session key vs. dedicated treasury EOA controlled by Core.
3. **maxFee policy** per app/route (who absorbs the Gateway fee — app ledger or a Portage spread).
4. **Governor multisig** composition and guardian pause scope.

---

## 12. Verification Log — hookData Execution (§11.1)

**Question:** Does Circle Gateway execute `hookData` during `gatewayMint` on Arc (automatic on-chain composition), or is it inert metadata requiring a separate Portage-side settle call?

**Method:** Verified from ground truth rather than a funded live test (cheaper, deterministic, no testnet funds needed).

1. **Deployed contract on Arc.** `GatewayMinter` (`0x0022222ABE238Cc2C7Bb1f21003F0a260052475B`) is a 163-byte ERC-1967 proxy → implementation `0x9ef4c7ad4f577be713972310e655337bfd0b84bf` (read from the standard impl slot `0x360894…382bbc`).
2. **Canonical source.** `github.com/circlefin/evm-gateway-contracts` → `src/modules/minter/Mints.sol`.
3. **`gatewayMint` → `_mint(spec)` (Mints.sol:333-353)** extracts `recipient`, `value`, `token`, `sourceDomain`, `depositor`, `signer`, then performs exactly one external call: `IMintableToken(minter).mint(recipient, value)` (line 349), and emits `AttestationUsed`.
4. **`hookData` is never read in the mint path.** Repo-wide, `hookData` appears only in `TransferSpec.sol` (byte offsets) and `TransferSpecLib.sol` (parsing, length checks, and inclusion in the EIP-712 spec hash at line 481). It is **not** extracted in `_mint`, **not** passed to any call, and **not** included in the `AttestationUsed` event.

**Result:** **Gateway does NOT auto-execute hooks.** `gatewayMint` is a plain "verify attestation → mint USDC to `destinationRecipient` → mark specHash used → emit event". `hookData` rides inside the Circle-signed `TransferSpec` (so it is tamper-evident) but triggers no on-chain action by itself.

**Consequence for Portage (primary flow chosen):** relayer/forwarder-driven, **not** native hook. Portage builds its own atomic composition via **`PortageMintForwarder`**, which in one transaction (a) decodes the authentic `hookData` from the attestation, (b) calls `gatewayMint` (USDC → `PortageRouter`), (c) calls `PortageRouter.credit(...)`. The burn intent pins `destinationRecipient = PortageRouter` and `destinationCaller = PortageMintForwarder` so only the forwarder can execute the mint — giving the atomicity and front-run protection a native hook would have, without depending on one.

*No live funded test executed — the canonical source + deployed-proxy verification is authoritative. A live mint can still be run later as a redundant confirmation if desired, but it would not change the design.*

---

## 13. Decision Log — PayoutMeta decoupled from Gateway hookData (v0.1)

**Finding (live, 2026-07-21).** During the first Coliseum end-to-end run, the Circle Gateway **testnet** transfer API (`POST /v1/transfer`) returned **500 Internal Server Error** whenever the burn intent carried non-empty `hookData`. Isolated with a controlled experiment on one real deposit (`sdk/e2e/hookdata-experiment.mjs`): identical spec, only `hookData` varied —

| hookData | Result |
|---|---|
| 192-byte PayoutMeta | ❌ 500 Internal server error |
| `0x` (empty) | ✅ success, attestation returned |

The payload matched Circle's documented schema (`hookData: ^0x[a-fA-F0-9]*$`, "arbitrary bytes", no documented length limit) and Circle's own sample (`arc-multichain-wallet`) — which **always** sends `hookData:"0x"` and never exercises non-empty hookData. A 500 (server crash) rather than a 400 (validation) on a schema-valid request indicates the Gateway testnet transfer path does not currently support non-empty hookData (unhandled server path). This is a **Gateway API limitation**, not a Portage bug — and it does not contradict §12 (the *minter* ignores hookData regardless; the problem is the *API* refusing to attest it).

**Decision: decouple PayoutMeta from the Gateway burn intent (option B1 — signed).** The burn intent is submitted with **empty hookData** (so the API works), and PayoutMeta travels as a **separate argument** to a new forwarder entrypoint, authorized by an **EIP-712 signature from the `sourceDepositor`** bound to the transfer's `specHash`.

```
executeMintWithMeta(attestation, signature, PayoutMeta meta, bytes metaSig)
  ├─ recipient == router                        (as before)
  ├─ specHash    = keccak(TransferSpec)          (from attestation)
  ├─ depositor   = sourceDepositor               (from attestation)
  ├─ recover(EIP712 PayoutMetaBinding{specHash, meta}, metaSig) == depositor   ← binds meta↔transfer↔user
  ├─ gatewayMint → USDC to router
  └─ router.credit(encode(meta), mintedΔ, specHash)
```

`PayoutMetaBinding` domain = `Portage / 1 / chainId(Arc) / verifyingContract(forwarder)`; typed fields `(bytes32 specHash, uint8 schema, bytes32 appId, bytes32 account, uint8 action, bytes32 referenceId, bytes32 payer)`.

**Why B1 (signed) and not B2 (unsigned arg).** With PayoutMeta as a plain unsigned argument, a compromised/malicious relayer could attach a *different* meta and misattribute a deposit to another app (isolation violation T5/T6 — funds land in the wrong app's balance; recoverable by governance but still a safety break). Binding meta to `specHash` with the depositor's signature restores the exact tamper-evidence hookData gave us (the user authorizes precisely which app/account/reference their deposit credits), so a relayer remains **liveness-only**. Cost is one extra EIP-712 signature per consolidation — acceptable.

**Security properties preserved.** Non-custodial (user signs both burn intent and meta binding); app isolation (meta bound to depositor + specHash; wrong/forged/tampered meta reverts — proven by `test_executeMintWithMeta_forgedMetaSig_reverts`, `…_metaSignedForDifferentSpecHash_reverts`, `…_tamperedMetaAfterSigning_reverts`); atomic mint+credit; unknown-app quarantine unchanged. The off-chain `specHash` the SDK computes was verified byte-for-byte equal to the on-chain decoder's (`transferSpecHash` ⟷ `AttestationDecoder.specHash`).

**Forward-compat.** The original hookData path is retained as `executeMint(attestation, signature)` for the day Gateway supports non-empty hookData end to end; the SDK's `buildConsolidationIntent` accepts an optional `hookData` override for that path. When that day comes, the meta can move back inline and the extra signature dropped — no Core change.

---

*Reference implementation studied: `circlefin/arc-multichain-wallet` (Gateway deposit → unified balance → mint). Portage reuses its EIP-712 `TransferSpec`/`BurnIntent` schema and Gateway API flow, but replaces custodial Developer-Controlled Wallets with non-custodial EOA signing and adds the per-app Core/periphery settlement layer described above. hookData execution semantics verified directly against `circlefin/evm-gateway-contracts` (§12).*
