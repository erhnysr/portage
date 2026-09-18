# Vendored Coliseum contracts — provenance

These are **verbatim copies** (no edits) of the Coliseum Arena source, vendored so Portage's
`VerdictCondition` can be tested against the **real** Arena contract on the local EVM (no testnet
RPC dependency). Source: https://github.com/erhnysr/coliseum — `contracts/src/`.

| File | Purpose |
|------|---------|
| `Arena.sol` | single judging arena — the decision organ behind `VerdictCondition` |
| `ArenaFactory.sol` | deploys/seeds arenas (imports `Arena.sol` + `ReputationNFT.sol`) |
| `ReputationNFT.sol` | reputation record minted to winners on `finalize()` |

Imports resolve against Portage's existing OpenZeppelin (`@openzeppelin/contracts/` → OZ 5.1.0 in
`lib/`). Compiles clean under solc 0.8.28.

## Commit / deployed-bytecode match

- `Arena.sol` last changed at Coliseum commit **`a15ca22`** ("feat: add vote reasoning transparency
  (event-only)", 2026-07-18), which is an ancestor of Coliseum `HEAD` and identical to `origin/main`.
  It has not changed since.
- The canonical Arc-testnet deployment recorded in Coliseum's committed Foundry broadcast
  (`broadcast/Deploy.s.sol/5042002/run-latest.json`, chain id 5042002) deploys:
  - `ArenaFactory` → `0x13a38e7C2bA5AFA76a1AC21Eaef9f4DEA293FEBe` (matches Coliseum README)
  - `ReputationNFT` → `0x953f508CdC9DC4FaA17D898a5e65A91a262F6607` (matches Coliseum README)
  - broadcast git commit `3012912` — an artifact-rebuild commit that post-dates `a15ca22`; the
    Arena source was unchanged between them, so the vendored source equals the deployed source.
- Arenas themselves are created by `ArenaFactory` (their runtime code is the factory's embedded
  `Arena` creation code), so a source match on `Arena.sol` covers the seeded arenas too.

## sha256 (as vendored)

- `Arena.sol`         `5247725e03ab7c7fa9dc4b007948b47789aa8c936f20a133dfbb19bc964a895b`
- `ArenaFactory.sol`  `0ee32181102e96d6f9132e67c736670efcfbc2b39f5b99bc6eee595fdd7b57ec`
- `ReputationNFT.sol` `b0b4d83865c35e13bf6f4e562a2eeb0635265c7355ba366d66e86579eece569c`

Note: this establishes provenance at the **git-commit / recorded-deployment** level. Exact on-chain
runtime-bytecode equality was not re-derived here (that would require an RPC pull + recompile with
identical settings); tests are intentionally kept RPC-free.
