/** Minimal ABIs for the Portage contracts the SDK interacts with. */

/**
 * All Portage custom errors that can bubble up through a forwarder/engine call. Included in the
 * write ABIs so viem decodes reverts by name instead of "reverted for an unknown reason".
 * (Note: a call to a non-existent function selector reverts with NO data and still can't be
 * decoded — that indicates a stale/incorrect deployment, not a custom error.)
 */
export const portageErrorsAbi = [
  // PortageMintForwarder
  { type: "error", name: "RecipientNotRouter", inputs: [{ name: "recipient", type: "address" }] },
  { type: "error", name: "NothingMinted", inputs: [{ name: "specHash", type: "bytes32" }] },
  {
    type: "error",
    name: "InvalidMetaSigner",
    inputs: [
      { name: "recovered", type: "address" },
      { name: "expectedDepositor", type: "address" },
    ],
  },
  // PortageRouter
  { type: "error", name: "NotForwarder", inputs: [{ name: "caller", type: "address" }] },
  { type: "error", name: "AlreadyProcessed", inputs: [{ name: "specHash", type: "bytes32" }] },
  // Ledger
  { type: "error", name: "NotCreditor", inputs: [{ name: "caller", type: "address" }] },
  { type: "error", name: "AppNotRegistered", inputs: [{ name: "appId", type: "bytes32" }] },
  { type: "error", name: "AppPaused", inputs: [{ name: "appId", type: "bytes32" }] },
  { type: "error", name: "ZeroAmount", inputs: [] },
  { type: "error", name: "TransferAlreadyProcessed", inputs: [{ name: "transferId", type: "bytes32" }] },
  {
    type: "error",
    name: "InsufficientAppBalance",
    inputs: [
      { name: "appId", type: "bytes32" },
      { name: "account", type: "bytes32" },
      { name: "requested", type: "uint256" },
      { name: "available", type: "uint256" },
    ],
  },
  // PayoutEngine
  { type: "error", name: "NotPayoutController", inputs: [
    { name: "appId", type: "bytes32" },
    { name: "caller", type: "address" },
  ] },
  { type: "error", name: "AlreadySettled", inputs: [
    { name: "appId", type: "bytes32" },
    { name: "referenceId", type: "bytes32" },
  ] },
] as const;

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
  ...portageErrorsAbi,
] as const;

const payoutMetaComponents = [
  { name: "schema", type: "uint8" },
  { name: "appId", type: "bytes32" },
  { name: "account", type: "bytes32" },
  { name: "action", type: "uint8" },
  { name: "referenceId", type: "bytes32" },
  { name: "payer", type: "bytes32" },
] as const;

export const mintForwarderAbi = [
  {
    type: "function",
    name: "executeMintWithMeta",
    stateMutability: "nonpayable",
    inputs: [
      { name: "attestationPayload", type: "bytes" },
      { name: "signature", type: "bytes" },
      { name: "meta", type: "tuple", components: payoutMetaComponents },
      { name: "metaSig", type: "bytes" },
    ],
    outputs: [],
  },
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
  {
    type: "function",
    name: "hashMetaBinding",
    stateMutability: "view",
    inputs: [
      { name: "specHash", type: "bytes32" },
      { name: "meta", type: "tuple", components: payoutMetaComponents },
    ],
    outputs: [{ name: "", type: "bytes32" }],
  },
  ...portageErrorsAbi,
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
