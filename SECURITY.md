# Security policy

Portage has not had an independent audit. The Arc mainnet deployment is a **capped pilot**:
the governor is the deployer key and transfers are kept to a few USDC. Do not hold more than
pilot amounts in it.

## Reporting a vulnerability

Report privately: https://github.com/erhnysr/portage/security/advisories/new

Please do not open a public issue. Include the affected contract or SDK function, steps to
reproduce and the impact you see. You will get a first answer within 72 hours.

## Scope

- Contracts in `contracts/core` and `contracts/periphery` (Arc mainnet pilot and Arc Testnet)
- The conditional-settlement layer in `contracts/conditional` (Arc Testnet)
- The TypeScript SDK in `sdk/` (`@erhnysr/portage-sdk`)

## Trust model and known limits

- Users sign burn intents with their own wallet; the SDK never holds keys.
- Every burn intent pins the PortageRouter as recipient and the PortageMintForwarder as the only
  caller. The depositor signs which app and sub-account a deposit credits; the forwarder checks
  that signature before crediting.
- Deposits for an unregistered app are quarantined on the router, never credited to another app.
- The governor can move quarantined funds and wire contracts. On the pilot it is a single key,
  not a multisig.
- Open findings and the path to production are tracked in
  [docs/MAINNET_READINESS.md](docs/MAINNET_READINESS.md); the audit scope is in
  [docs/AUDIT_SCOPE.md](docs/AUDIT_SCOPE.md).
