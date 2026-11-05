# Quickstart

Move 1 USDC from Base Sepolia into an app balance on Arc Testnet, then pay it out.
The scripts are in [`examples/`](../examples) and typecheck against `@erhnysr/portage-sdk@0.2.0`.

## Prerequisites

- Node 20+
- A **depositor** key with Base Sepolia USDC (https://faucet.circle.com) and a little Base Sepolia ETH for gas
- A **relayer** key with a little Arc Testnet USDC for gas (Arc uses USDC as gas; can be the depositor key)
- For payouts: the key registered as your app's `payoutController` in the AppRegistry

```bash
cd examples
npm install
```

## 1. Consolidate

```bash
DEPOSITOR_KEY=0x... RELAYER_KEY=0x... npm run consolidate
```

1. Builds the burn intent first. That fixes `maxFee`, the most the Gateway transfer may charge
   (SDK default: 10% of the amount, capped at 2.01 USDC).
2. Approves and deposits `amount + maxFee` into Circle's GatewayWallet on Base Sepolia.
3. Waits until Circle has finalized the deposit (its balance lags the onchain transaction).
4. The depositor signs the burn intent, plus a second signature that binds the `PayoutMeta`
   (which app and sub-account to credit) to the transfer's spec hash.
5. Gateway returns an attestation for Arc.
6. Any relayer calls `executeMintWithMeta` on Arc: the USDC is minted and credited to the app's
   ledger in one transaction. The forwarder rejects meta the depositor did not sign.

The script prints the deposit and credit transactions and the new app balance.

## 2. Pay out

```bash
CONTROLLER_KEY=0x... WINNER=0x... npm run payout
```

`payout()` debits the app's sub-account and sends USDC to the recipient. The `referenceId` is
single-use, so a second run prints `already paid` instead of paying twice.

## Networks

| `network` | Arc chain | Source chains | Status |
|---|---|---|---|
| `arcTestnet` (default) | Arc Testnet, 5042002 | `baseSepolia`, `ethereumSepolia`, `arbitrumSepolia`, `avalancheFuji`, `arcTestnet` | Live; conditional escrow and Arena deployed |
| `arcMainnet` | Arc mainnet, 5042 | `base`, `ethereum`, `arbitrum`, `avalanche` | **Capped pilot**: unaudited, a few USDC only |

Pass `network: "arcMainnet"` to `PortageClient` / `PortagePayouts` for the pilot. Selecting a
source chain the network does not support throws a clear error.

## Next

- How it works and the threat model: [ARCHITECTURE.md](ARCHITECTURE.md)
- Every SDK method: [sdk/README.md](../sdk/README.md)
- What is verified on mainnet and what is not: [MAINNET_READINESS.md](MAINNET_READINESS.md)
- Reporting a vulnerability: [SECURITY.md](../SECURITY.md)
