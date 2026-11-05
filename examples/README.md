# Portage examples

Two runnable scripts on Arc Testnet. See [docs/QUICKSTART.md](../docs/QUICKSTART.md) for the walkthrough.

| Script | What it does |
|---|---|
| `consolidate.ts` | Base Sepolia USDC → Circle Gateway → atomic mint + credit into an app balance on Arc |
| `payout.ts` | Idempotent payout from that app balance to a recipient |

```bash
npm install
DEPOSITOR_KEY=0x... RELAYER_KEY=0x... npm run consolidate
CONTROLLER_KEY=0x... WINNER=0x... npm run payout
npm run typecheck
```

Never commit private keys. Use throwaway testnet keys.
