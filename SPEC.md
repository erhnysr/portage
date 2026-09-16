# Portage — Conditional Settlement Layer

**Status:** Draft / §8 answered — ready for failing-first tests
**Scope:** `ConditionalEscrow` + `ConditionRegistry` + `ISettlementCondition` and its first implementations
**Out of scope:** any change to the deployed Portage core (AppRegistry, Ledger, PayoutEngine, PortageRouter, PortageMintForwarder) or to the deployed Arena contracts

---

## 1. Purpose

Portage currently executes unconditional cross-chain USDC payouts. This layer adds the missing half: a payer can lock USDC against a *condition*, and the funds are released only when that condition resolves into a concrete allocation.

Conditions are pluggable. The first four:

| Condition | Resolves when |
|---|---|
| `MutualReleaseCondition` | both parties sign off |
| `TimelockCondition` | a deadline passes with no objection |
| `AttestationCondition` | a designated attester (DID/EOA) signs |
| `VerdictCondition` | an on-chain arena returns a final verdict |

`VerdictCondition` is an adapter over the already-deployed `ArenaFactory`. The arena contracts are **not** modified or redeployed.

---

## 2. Design decisions

These are fixed for v1. Each one narrows the attack surface.

**D1 — USDC only.** No multi-asset support. A single, known, non-rebasing, non-callback ERC-20 removes an entire class of token-behaviour bugs.

**D2 — Pull, not push.** Resolution does not transfer funds. It records an allocation; each recipient claims separately. A recipient who cannot receive (reverting contract, USDC blocklist) harms only themselves and cannot block other recipients or wedge the deal.

> **Rationale corrected (see §8.1).** The original rationale cited a failing cross-chain leg. That rationale is wrong — the cross-chain leg is deposit-side only; release is entirely same-chain on Arc. However D2 **stands on a different and stronger ground**: `PayoutEngine.distribute` reverts the entire batch if any single debit fails (`PayoutEngine.sol:72-73`, `:87-91`). Since USDC enforces a blocklist, one blocked recipient would wedge a whole multi-recipient allocation. Pull is therefore mandatory, and is implemented via per-recipient `PayoutEngine.payout` calls (§2.1).

**D3 — Registry-gated conditions.** A deal may only be opened against a condition address approved in a governor-controlled registry. An arbitrary contract must never be attachable.

> **Amended (see §8.2).** The original text said "approved in `AppRegistry`". No such mechanism exists there. D3 is now served by a **new `ConditionRegistry` contract** — see §2.2.

**D4 — Refund never touches the condition.** The timeout refund path makes no external call into the condition contract. A condition that reverts forever, self-destructs, or hangs must not be able to trap funds.

**D5 — Snapshot on resolve.** `resolve()` reads the condition exactly once and stores the resulting allocation. Later state changes inside the condition cannot alter a resolved deal.

**D6 — Fail closed.** If a condition returns something malformed (allocations that do not sum to the deal amount, an unknown recipient, an empty set while claiming to be settled), `resolve()` reverts. It never falls through to a partial or default settlement.

**D7 — Core untouched.** The existing invariant coverage on Portage core (12 checks, ~393k invariant calls) must remain valid without modification. This layer sits above it.

**D8 — Single custody. (new)** Escrowed principal lives in the Portage `Ledger`, never in the escrow contract's own balance and never in an Arena. The Arena is a decision organ only. See §2.1 and §7.

---

### 2.1 Custody and settlement mechanics

This is the concrete resolution of §8.1 / §8.3 and replaces any assumption that the escrow is an opaque holder.

```
Escrow principal:   Ledger.balances[appId][dealId]
Escrow contract:    registered as payoutControllerOf(appId)
Funding:            Gateway deposit with PayoutMeta{appId, account: dealId,
                    action: PayoutAction.ESCROW_FUND}  → PortageRouter → Ledger.credit
Claim (per recipient):
    payoutEngine.payout(
        appId,
        dealId,                                   // account
        keccak256(abi.encode(dealId, recipient)), // referenceId — one-shot
        recipient,
        amount
    )
Refund:             same call shape, recipient = payer, no condition call (D4)
```

**D9 — `appId` is a parameter, not a constant.** `open()` takes the `appId` from the caller and MUST verify `registry.payoutControllerOf(appId) == address(this)`, reverting otherwise. Without that check a deal could be opened under an app the escrow does not control: funds would be credited and every later `payout()` would revert with `NotPayoutController`, trapping them permanently.

Granularity rationale (answers O2): per-deal apps are not feasible — `registerApp` is `onlyOwner` (`AppRegistry.sol:57`), so each new deal would need a governor multisig transaction, killing permissionless deal creation. Per-integrator is the granularity `AppRegistry` was designed for. v1 registers a single app; a second integrator requires a governor `registerApp` call and **no contract change**. It also narrows T13's blast radius: a pause freezes one integrator, not every deal in the system.

Why this shape:

- **Core is untouched.** `PayoutEngine.payout` (`PayoutEngine.sol:58-68`) already authorises via `onlyPayoutController` (`:45-50`). Attaching the escrow requires a registry configuration, not a code change. D7 holds literally.
- **Pull semantics preserved.** One `payout` call per recipient per claim. A blocked or reverting recipient reverts only their own call (T10).
- **Double-claim protection is doubled.** `_markSettled` (`PayoutEngine.sol:97-102`) reverts with `AlreadySettled` on a repeated `referenceId`, independently of the escrow's own accounting. I4 is enforced in two places.
- **Solvency is inherited.** Escrow funds sit inside the Ledger's `custodyTotal`, so the existing I1–I4 invariants (`Ledger.sol:27-30`) cover the escrowed principal. No second vault, no second accounting model.
- **Emergency freeze is free.** `Ledger.debit` checks `registry.isPaused(appId)` (`Ledger.sol:152`), so the guardian can halt escrow outflows. **Trade-off, accepted and documented:** a paused escrow app also blocks `refund()`, which weakens I7 under an active pause. This is deliberate — a guardian pause is an emergency stop, and the alternative (a refund path that bypasses pause) is a worse failure mode.

### 2.1b Funding path — a hard constraint

`Ledger.credit` is `onlyCreditor` (`Ledger.sol:121`) and `creditor` is a **single address** (`:39`, `:99-103`), currently `PortageRouter`. There is no second creditor slot. The escrow therefore **cannot** pull USDC from a payer directly; making it the creditor would displace the router and break the deposit path.

Consequence, and it must be stated plainly in the README: **a deal can only be funded by a Circle Gateway deposit.** A user who already holds USDC on Arc cannot open an escrow without routing funds through Gateway from another chain. For v1 this is accepted — Portage is a cross-chain settlement product and "bring funds from another chain and bind them to a condition" is a coherent story — but it is a real limitation, not an implementation detail.

The deposit carries `PayoutMeta{appId, account: dealId, action: PayoutAction.ESCROW_FUND}`. That action constant **already exists in the deployed code** (`PayoutMetaLib.sol:20`), so no core change is needed to express escrow funding.

**The escrow receives no callback when funds land.** The router credits the Ledger without the escrow's knowledge. `open()` must therefore verify funding by reading `ledger.balanceOf(appId, dealId)` rather than by receiving tokens. Three consequences, all decided:

**D10 — `dealId` commits to the payer.** `dealId = keccak256(abi.encode(payer, salt, conditionAddr, amount, hardDeadline))`, and `open()` recomputes it from its arguments and requires `msg.sender == payer`.

This closes a theft vector that a naive design has. Credited funds are visible on-chain before `open()` is called, and `open()`'s only funding check is a balance read. Without D10, anyone who sees a deposit land on an un-opened `dealId` can front-run the real payer, call `open()` with themselves as the sole recipient and a condition that resolves immediately, and take the deposit. With D10 an attacker cannot produce a `dealId` that both matches the funded account and passes the `msg.sender == payer` check.

**D11 — Late credits are never a top-up.** A deal's `amount` is fixed at `open()`. Anything credited to `(appId, dealId)` afterwards is unaccounted surplus, recoverable only via D12. Allowing top-ups would make `amount` mutable and force changes to I2, I13 and the state machine for a case the product does not need.

**D12 — Unaccounted surplus is swept by the governor.** The escrow maintains `outstanding[appId][account]`, incremented on `open()` and decremented on each `claim()` and `refund()`. A governor-only `sweepUnaccounted(appId, account, to)` pays out exactly `ledger.balanceOf(appId, account) - outstanding[appId][account]`, via `payoutEngine.payout` with a nonce-derived `referenceId` so repeated sweeps do not collide.

One function covers both hazards: a `dealId` that was funded but never opened has `outstanding == 0`, so its whole balance is sweepable; a late credit to an open deal is the difference. The subtraction is what makes this safe — an active deal's principal can never be swept, by construction.

Governor-only rather than payer-triggered, because the escrow cannot identify the payer of an un-opened deposit: `PayoutMeta.payer` is carried through the router but is not stored in the Ledger. This mirrors the precedent the codebase already sets — `PortageRouter` handles the analogous "funds arrived, destination unclear" case with quarantine plus governor resolution (`PortageRouter.sol:90-108`).

### 2.2 `ConditionRegistry` (new contract)

`AppRegistry` is documented as immutable PortageCore (`AppRegistry.sol:13-14`) and holds only app identity/access state. Adding a condition allowlist to it would break that claim and require redeploying a core contract.

Instead: a separate `ConditionRegistry`, governor-owned, holding `mapping(address condition => bool approved)`. The T11 trust assumption moves here, and the v2 timelock is added here rather than to core.

---

## 3. Interface

```solidity
interface ISettlementCondition {
    /// @notice Report whether this deal's condition is finally resolved.
    /// @dev MUST be free of side effects that depend on the caller.
    ///      MUST return settled=false unless the outcome is final and immutable.
    ///      MUST NOT return an allocation whose recipients are outside the
    ///      participant set the escrow registered at open time.
    /// @return settled      true only if the outcome is final
    /// @return recipients   addresses to be paid
    /// @return amounts      parallel array; MUST sum to the full deal amount
    function resolve(bytes32 dealId)
        external
        view
        returns (bool settled, address[] memory recipients, uint256[] memory amounts);
}
```

`view` is deliberate. The escrow must be able to read the outcome without granting the condition an opportunity to reenter or mutate state during resolution.

---

## 4. State machine

```
                 open()
      (none) ──────────────▶ Funded
                              │  │
                    activate()│  │ resolve()
                              ▼  │
                          Resolving
                              │  │
                    resolve() │  │
                              ▼  ▼
                           Resolved ──── claim() ×N ────▶ Claimed
                              
      Funded ─┐
              ├── refund()  (only after hardDeadline) ──▶ Refunded
   Resolving ─┘

      Funded ──── cancel() (unanimous, pre-resolution) ──▶ Cancelled
```

| State | Meaning |
|---|---|
| `Funded` | USDC credited to `Ledger.balances[escrowAppId][dealId]`, condition attached, nothing contested yet |
| `Resolving` | condition is actively running (e.g. arena open, jury voting) |
| `Resolved` | allocation snapshotted; funds claimable |
| `Claimed` | every allocation withdrawn — terminal |
| `Refunded` | hard deadline passed with no resolution; payer recovered funds — terminal |
| `Cancelled` | all participants agreed to unwind before resolution — terminal |

`Resolved`, `Claimed`, `Refunded`, `Cancelled` are terminal with respect to the settlement decision. No transition out of them exists.

---

## 5. Invariants

Each of these becomes a failing-first test before any implementation is written.

### Solvency

- **I1** — `Ledger.appBalance(appId) >= Σ outstanding[appId][account]` over all accounts. The inequality, not equality: unaccounted surplus (D11) may sit above the sum until swept. No deal can be paid out of another deal's funds.
- **I2** — For a resolved deal, `sum(amounts) == deal.amount` exactly. Not less, not more.

### Single settlement

- **I3** — `resolve()` succeeds at most once per deal.
- **I4** — Each recipient claims at most once per deal; the total claimed never exceeds `deal.amount`. Enforced independently by the escrow and by `PayoutEngine._markSettled`.
- **I5** — `resolve()` and `refund()` are mutually exclusive. No deal is ever both resolved and refunded.
- **I6** — `cancel()` is impossible once a deal has reached `Resolved`.

### Liveness — no permanently locked funds

- **I7** — For every deal, after `hardDeadline`, at least one terminal path is reachable by at least one honest participant, with no cooperation required from any other party or from the condition contract. **Qualified:** this does not hold while `escrowAppId` is paused by the guardian (§2.1). The test asserts the unpaused case and documents the paused case.
- **I8** — A condition that always reverts, returns garbage, or has no code cannot prevent `refund()`.

### Authorization and integrity

- **I9** — Only a condition address approved in `ConditionRegistry` at open time can be attached.
- **I10** — The condition attached at `open()` is immutable for the life of the deal.
- **I11** — Every recipient in a resolved allocation is a member of the participant set registered at `open()`. A condition cannot introduce a new payee.
- **I12** — Only the designated recipient may claim their own allocation.
- **I13** — `hardDeadline` is set at `open()` and cannot be extended or shortened afterwards.
- **I17** — `open()` reverts unless `registry.payoutControllerOf(appId) == address(this)` (D9). No deal can exist under an app whose payouts the escrow cannot execute.
- **I18** — `open()` reverts unless `ledger.balanceOf(appId, dealId) >= amount` at call time. No deal is ever in a state where its recorded amount exceeds its backing.
- **I19** — `open()` reverts unless `dealId == keccak256(abi.encode(payer, salt, condition, amount, hardDeadline))` and `msg.sender == payer` (D10). No party other than the payer can open a deal against a funded account.
- **I20** — `sweepUnaccounted` can never reduce `ledger.balanceOf(appId, account)` below `outstanding[appId][account]`, in any state, including mid-claim on a partially claimed deal.

### Ordering and reentrancy

- **I14** — Checks-Effects-Interactions holds on every state-changing function. `claim()` marks the allocation consumed before calling `PayoutEngine.payout`.
- **I15** — A reentrant call into any escrow entry point during a transfer cannot produce a second payout, a second resolve, or a resolve-after-refund.
- **I16** — A deal resolved at block *N* yields the identical allocation when read at block *N+k*, regardless of any condition state change in between.

---

## 6. Threat model

Actors: payer, payee(s), juror, condition author, registry owner, arbitrary caller.

| # | Threat | Mitigation |
|---|---|---|
| T1 | Malicious condition returns itself (or an attacker) as recipient | I11 participant-subset check, I9 registry gating |
| T2 | Malicious condition returns amounts summing above the deal | I2 exact-sum check, revert on mismatch (D6) |
| T3 | Malicious condition returns amounts summing below the deal, leaving a residue | I2 — under-allocation reverts too; residue is not silently retained |
| T4 | Double claim | I4 + I14 (mark before transfer) + `PayoutEngine` referenceId one-shot |
| T5 | Griefing: counterparty never triggers the condition | I7 hard-deadline refund |
| T6 | Condition contract bricked or reverting forever | D4 + I8 — refund path makes no call into it |
| T7 | Reentrancy through the token or a recipient contract | D1 (USDC has no transfer hook) + I14/I15, plus `nonReentrant` on `PayoutEngine.payout` and `Ledger.debit` |
| T8 | Front-running `resolve()` to land a different outcome | I3 single resolve + D5 snapshot; outcome is determined by condition state, not by call ordering |
| T9 | Verdict flips between the arena's finalisation and the escrow's read | **Confirmed real — see note below.** `VerdictCondition` MUST read `Arena.finalized`, never `getPhase()` |
| T10 | Recipient is a contract that reverts on receipt, or is USDC-blocklisted, wedging the whole deal | D2 pull model + per-recipient `payout` calls isolate the failure |
| T11 | Registry owner approves a malicious condition | **Accepted trust assumption for v1.** Documented, not mitigated. Lives in `ConditionRegistry`; a timelock on additions is the v2 mitigation. |
| T12 | Cross-chain leg fails after the deal is marked claimed | **Closed — see §8.1.** The cross-chain leg is deposit-side only. Release is same-chain on Arc. There is no post-claim cross-chain leg to fail. |
| T13 | Guardian pause blocks refund, trapping funds for the duration | **Accepted, documented (§2.1).** Pause is an emergency stop; a pause-bypassing refund is the worse failure mode. |
| T14 | Attacker front-runs `open()` on a funded but un-opened `dealId`, naming themselves recipient, and steals the deposit | D10 payer-committed `dealId` + `msg.sender == payer`; I19 |
| T15 | Governor sweeps an active deal's principal via `sweepUnaccounted` | D12 subtracts `outstanding` before paying; I20 asserts it in every state |

### Note on T9 — confirmed against source

`Arena.getPhase()` (`Arena.sol:277-281`) returns `Phase.Ended` based **only** on `block.timestamp >= votingDeadline`. It never reads `finalized`. Since `finalize()` is permissionless (`Arena.sol:157`) and may be called at any time — or never — the window between "voting closed" and "verdict recorded" is unbounded.

This is the same root cause as the sealed-badge bug already fixed in the Coliseum frontend: conflating the `Ended` phase with the `finalized()` boolean.

Mitigating facts, also confirmed: `finalized` (`Arena.sol:60`) and `winners` (`:61`) are both public and are each written exactly once, inside `finalize()` (`:161`, `:190`). A full grep of `Arena.sol` shows no other mutation site and no admin override. So a verdict, once recorded, is immutable (§8.5) — the race is one-directional: premature read, never post-hoc alteration.

`VerdictCondition.resolve()` therefore returns `settled = arena.finalized()` and reads `arena.getWinners()` only when that is true. `getPhase()` is not used anywhere in the condition.

This must still be closed with an actually-executed adversarial test with the calls interleaved, not an argument that it is safe.

---

## 7. Coliseum absorption

Nothing is redeployed. The mapping is:

| Existing | Becomes |
|---|---|
| `ArenaFactory` / `Arena` | the dispute engine behind `VerdictCondition` — **decision organ only** |
| `ReputationNFT` | counterparty reputation record written on resolution |
| Arena frontend (marble / verdict-seal, live on Vercel) | the product's demo surface |

### Two-vault resolution (answers §8.3)

`Arena` holds its own USDC directly (`Arena.sol:295` `_usdcBalance()`), entirely outside the Portage `Ledger`. It is not counted in `custodyTotal` and is not covered by I1–I4.

**Decision: the escrowed principal never enters an Arena.** The Arena keeps its own small economy — submission fees (`Arena.sol:32`), vote stakes (`:33`), winner prizes and voter rebates — as a **juror incentive layer**. That pot is small, self-contained, and already deployed. The settlement principal stays in the Ledger under D8 and is released by `ConditionalEscrow`.

This is possible because the Arena exposes everything `VerdictCondition` needs as public reads: `finalized` (`:60`), `winners` (`:61`), `getWinners()` (`:287`), and the fixed 60/30/10 split constants (`:38-40`). The condition derives the allocation ratio from the arena's outcome and applies it to the escrowed amount, without touching the arena's funds.

`ReputationNFT` gains its real purpose here. Standing alone it is a decorative seal. Inside a settlement rail it is an answer to "has this counterparty been in a dispute before, and did they lose it" — which is exactly the question a payment counterparty, human or agent, needs answered.

---

## 8. Verification — ANSWERED

Each item below was confirmed against the actual deployed source with file:line evidence.

**8.1 — `PayoutEngine` cross-chain failure semantics.**
Two distinct layers, both confirmed:
- *Mint (inbound) leg:* `PortageMintForwarder._mintToRouter` reverts with `NothingMinted(specHash)` if the measured balance delta is zero (`PortageMintForwarder.sol:132-134`). Atomic — no queue, no partial state.
- *Post-mint credit leg:* funds already minted and irreversible are **not** reverted. `PortageRouter` quarantines them (`PortageRouter.sol:35-56`, resolution at `:90-108`) under a `QuarantineReason`, for governor resolution via `resolveQuarantineToApp` or `withdrawQuarantine`.
- *Release (outbound) leg:* **entirely same-chain.** `PayoutEngine.payout` → `Ledger.debit` → `usdc.safeTransfer` (`Ledger.sol:167`). No cross-chain component exists after the deposit.

→ **T12 closes.** → **D2's rationale is replaced** (see D2 note); note that `distribute` reverts the whole batch on any single failure (`PayoutEngine.sol:72-73`), which is why per-recipient `payout` is used instead.

**8.2 — `AppRegistry` approval mechanism for D3.**
**None exists.** Full read of `AppRegistry.sol`: the `AppConfig` struct holds only `exists`, `paused`, `owner`, `payoutController` (`:23-28`). There is no condition allowlist, no generic approval mapping, and no extension point. Control today: `owner()` is the Portage governor, expected to be a multisig (`:15-16`).

→ **D3 amended.** A new `ConditionRegistry` is required (§2.2). AppRegistry is explicitly documented as immutable core (`:13-14`) and is not modified.

**8.3 — Ledger representation of escrow balance.**
**Must be represented in the Ledger.** `Ledger.sol:20` documents `account` as "Sub-account within the app (app-defined, e.g. an arena id)" — the escrow's `dealId` fits this exactly. An opaque external holder would break I1–I4 (`Ledger.sol:27-30`), since `custodyTotal == Σ appTotal` cannot hold for value held outside the vault.

→ **D8 added.** Escrow principal lives at `Ledger.balances[escrowAppId][dealId]`.

**8.4 — Arena verdict: allocation or binary?**
**Allocation, not binary.** `finalize()` computes concrete amounts from fixed basis-point constants `SPLIT_1ST = 6_000`, `SPLIT_2ND = 3_000`, `SPLIT_3RD = 1_000` (`Arena.sol:38-40`) and writes them to `pendingWithdraw` (`:189-207`), including collapse-to-first when 2nd/3rd slots are unfilled (`:201-207`) and rounding dust to the creator (`:228-232`).

→ **`VerdictCondition`'s spec does not change in the way §8.4 feared** — no split rule needs inventing. But the split is applied to the *arena's own pot*, not to the escrowed amount, so `VerdictCondition` derives the *ratio* and applies it to `deal.amount`. Rounding dust handling must be specified in the condition (proposal: dust to the payer, mirroring the arena's dust-to-creator rule).

**8.5 — Can a finalised verdict be altered?**
**No.** `finalized` and `winners` are written exactly once each, both inside `finalize()` (`Arena.sol:161`, `:190`). A full grep of `Arena.sol` for assignments to either shows no other site. `require(!finalized, "Arena: already finalized")` (`:159`) blocks re-entry. There is no admin override, dispute, or re-open path.

**8.6 — Invariant harness extensibility.**
**Yes, no structural obstacle.** The existing 12 invariants are split across `LedgerInvariant.t.sol` (5), `PayoutEngineInvariant.t.sol` (4), and `PeripheryInvariant.t.sol` (3), all using the standard Foundry handler pattern: a dedicated handler contract, `targetSelector`/`targetContract` wiring, and `invariant_`-prefixed assertions (`LedgerInvariant.t.sol:47-54`). A new `EscrowHandler` plus new `invariant_` functions follows the same shape.

Incidental: `LedgerInvariant.t.sol:24` already seeds `keccak256("coliseum")` as a test app id — the consolidation was anticipated in the fixture.

---

## 9. Arc mainnet status (as of 2026-09-16)

Arc public mainnet launched today: permissionless contract deployment, USDC-denominated gas, permissioned validator set.

**Portage mainnet is gated on Circle Gateway availability on Arc mainnet, which is not yet confirmed.** Circle's Gateway documentation lists Arc under *testnet* (domain 26); Gateway's mainnet launch covered seven chains with Arc stated as "next". Until Gateway is live on Arc mainnet, the `PortageRouter` / `PortageMintForwarder` deposit path has no counterpart there.

Consequences:
- The `arcMainnet` config fields stay `PENDING`. No values are invented. Populate only from Circle's own documentation and verify each address against the chain before merge.
- Mainnet launch creates no deadline pressure on this layer. Finish on testnet, then deploy when Gateway lands.
- This layer's contracts are new and unaudited. They do not go to mainnet before §9 of the build order (adversarial review) is complete, regardless of Gateway availability.

---

## 10. Build order

1. ~~`SPEC.md` — this document, reviewed and frozen~~
2. ~~Answer §8 against real source~~ — done, see §8
3. Failing-first tests for I1–I16
4. `ConditionRegistry` (trivial — unblocks D3/I9 in the tests)
5. `ConditionalEscrow`
6. `MutualReleaseCondition` (simplest — proves the interface)
7. `TimelockCondition`
8. `AttestationCondition`
9. `VerdictCondition` (last — highest complexity)
10. Adversarial review, including executed concurrency tests for T9
11. Deploy to Arc Testnet, verify on ArcScan
12. Monorepo consolidation and SDK update

Nothing in steps 4–9 begins before step 3 is red.

### Decided

- **O1 — Rounding dust → largest allocation.** Not to the payer. Sending 1–2 atomic units (0.000001 USDC) to a separate recipient costs an extra `payout()` call whose gas exceeds the amount many times over. Adding the remainder to the largest allocation keeps `sum(amounts) == deal.amount` exactly (I2), introduces no extra recipient, and adds no call. The microscopic advantage to the top winner is documented, not hidden.
- **O2 — `appId` is a parameter; v1 ships with one registered app.** See D9.
- **O3 — One-time governor action per integrator.** `registerApp(appId, governor, escrowAddress)` sets owner and payoutController in a single call (`AppRegistry.sol:57-65`). It belongs in the deployment script and is repeated for each new integrator, not for each deal.

### Open before step 3

- **O4 — Gateway-only funding.** README and SDK must state the constraint (§2.1b) before anyone integrates against a mistaken assumption. Documentation task, not a design question.
- **O5 — Decided.** Funds credited to an un-opened `dealId` are recovered by `sweepUnaccounted` (D12), governor-only.
- **O6 — Decided.** Late credits are unaccounted surplus, never a top-up (D11).
