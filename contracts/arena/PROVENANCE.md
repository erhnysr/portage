# Arena contracts — absorbed from Coliseum

These are **verbatim copies** (no edits) of the Coliseum Arena contracts, absorbed into the Portage
monorepo per SPEC §7 (Coliseum absorption) so `VerdictCondition` resolves against the real Arena.
Source: https://github.com/erhnysr/coliseum — `contracts/src/`.

| File | Role |
|------|------|
| `Arena.sol` | single judging arena — the decision organ behind `VerdictCondition` |
| `ArenaFactory.sol` | deploys/seeds arenas |
| `ReputationNFT.sol` | soulbound reputation record minted to winners on `finalize()` |

They compile under Portage's toolchain unchanged: solc 0.8.28, OpenZeppelin 5.1.0 (the `lib/`
submodule), remapping `@openzeppelin/contracts/`. Nothing is redeployed (SPEC §7); the deployed
Arc-testnet instances remain canonical.

## Commit / deployed-bytecode match

- `Arena.sol` last changed at Coliseum commit **`a15ca22`** (ancestor of Coliseum `HEAD`, identical
  to `origin/main`), unchanged since.
- Coliseum's committed Foundry broadcast (chain id 5042002) deploys `ArenaFactory` →
  `0x13a38e7C2bA5AFA76a1AC21Eaef9f4DEA293FEBe` and `ReputationNFT` →
  `0x953f508CdC9DC4FaA17D898a5e65A91a262F6607` (both match the Coliseum README) from an
  artifact-rebuild commit post-dating `a15ca22` with the Arena source unchanged — so this source
  equals the deployed source.

The Coliseum contract tests live at `test/arena/` (`Arena.t.sol`, `ArenaFactory.t.sol`,
`ReputationNFT.t.sol`), likewise copied verbatim except for import paths.
