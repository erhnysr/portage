/** Minimal ABIs for the Portage contracts the SDK interacts with. */

export const ledgerAbi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [
      { name: "appId", type: "bytes32" },
      { name: "account", type: "bytes32" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "appBalance",
    stateMutability: "view",
    inputs: [{ name: "appId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "custodyTotal",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalCredited",
    stateMutability: "view",
    inputs: [{ name: "appId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "totalPaid",
    stateMutability: "view",
    inputs: [{ name: "appId", type: "bytes32" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export const payoutEngineAbi = [
  {
    type: "function",
    name: "payout",
    stateMutability: "nonpayable",
    inputs: [
      { name: "appId", type: "bytes32" },
      { name: "account", type: "bytes32" },
      { name: "referenceId", type: "bytes32" },
      { name: "recipient", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "distribute",
    stateMutability: "nonpayable",
    inputs: [
      { name: "appId", type: "bytes32" },
      { name: "account", type: "bytes32" },
      { name: "referenceId", type: "bytes32" },
      { name: "recipients", type: "address[]" },
      { name: "amounts", type: "uint256[]" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "settled",
    stateMutability: "view",
    inputs: [
      { name: "appId", type: "bytes32" },
      { name: "referenceId", type: "bytes32" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

export const mintForwarderAbi = [
  {
    type: "function",
    name: "executeMint",
    stateMutability: "nonpayable",
    inputs: [
      { name: "attestationPayload", type: "bytes" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

export const appRegistryAbi = [
  {
    type: "function",
    name: "isRegistered",
    stateMutability: "view",
    inputs: [{ name: "appId", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "isPaused",
    stateMutability: "view",
    inputs: [{ name: "appId", type: "bytes32" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "payoutControllerOf",
    stateMutability: "view",
    inputs: [{ name: "appId", type: "bytes32" }],
    outputs: [{ name: "", type: "address" }],
  },
] as const;

/** GatewayWallet.deposit(token, value) — used on the source chain to fund the unified balance. */
export const gatewayWalletAbi = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "token", type: "address" },
      { name: "value", type: "uint256" },
    ],
    outputs: [],
  },
] as const;
