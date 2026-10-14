# Portage — audit scope (draft)

**Purpose:** scope note for an independent security review before any mainnet deployment.
Portage is open source, experimental and **unaudited**.

## In scope
| Contract | Path | Notes |
|----------|------|-------|
| AppRegistry | `contracts/core/AppRegistry.sol` | app identity, pause, guardian |
| Ledger | `contracts/core/Ledger.sol` | USDC custody, credit-once, debit, solvency |
| PayoutEngine | `contracts/core/PayoutEngine.sol` | payout authorization, replay protection |
| PortageRouter | `contracts/periphery/PortageRouter.sol` | attribution, quarantine, governor recovery |
| PortageMintForwarder | `contracts/periphery/PortageMintForwarder.sol` | atomic mint + credit, EIP-712 meta binding |
| Libraries | `contracts/lib/*.sol`, `contracts/interfaces/IGatewayMinter.sol` | attestation decoding, meta encoding |

Out of scope unless requested: `contracts/arena/*`, `contracts/conditions/*` (Coliseum / conditional
settlement layer), `web/`, `sdk/`.

## Key properties to attack
1. `custodyTotal == Σ appTotal` and solvency under any call sequence.
2. App isolation: no path moves one app's funds via another app's controller.
3. A deposit is credited at most once per `specHash` and never mis-credited (quarantine instead).
4. `executeMintWithMeta`: signer must equal the attestation's `sourceDepositor`; front-running and
   orphaned-mint resistance (`destinationCaller = forwarder`, `destinationRecipient = router`).
   Note the forwarder itself is permissionless, so `destinationCaller = forwarder` does not stop a
   third party from calling the forwarder's other entrypoint (`executeMint`) — see finding A in
   `docs/MAINNET_READINESS.md`.
5. Balance-delta accounting in `_mintToRouter` when the router also holds quarantined USDC.
6. Governor powers (quarantine withdraw/resolve, wiring) and the two-step ownership transfer.
7. Native USDC precision (18-decimal native vs 6-decimal ERC-20 interface) at all boundaries.

## Known limitations (disclose to the reviewer)
- No global pause; guardian is optional and unset by default; no deposit/app caps.
- Governor can withdraw quarantined funds to any address.
- `executeMint` (hookData path) is forward-compat only; Gateway testnet returned 500 on non-empty hookData.
  On the current code it also accepts empty hookData, which lets anyone force a v0.1 deposit into
  quarantine (finding A). USDC that reaches the router outside the forwarder cannot be recovered
  (finding B). Fixes for both are on branch `hardening/mainnet-prep`; review that branch, not `main`.
- Meta signatures are ECDSA only (no ERC-1271 smart-wallet depositors).
- Tests: 81 Portage core/periphery tests including 12 fuzz invariants, all passing on 2026-10-14
  (232 in the whole repo; 246 on the hardening branch).
- Gateway and Arc mainnet behavior has not been exercised by Portage; only Arc Testnet.

## Build
`forge build && forge test` (Solidity 0.8.28, OpenZeppelin 5.1.0 submodule under `lib/`).
