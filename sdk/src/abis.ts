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

// ===========================================================================
// Conditional-settlement layer (SPEC §2–§7). Minimal ABIs for the members the
// SDK calls, plus each contract's custom errors so viem decodes reverts by name.
// ===========================================================================

/** Shared custom errors of ConditionalEscrow (from IConditionalEscrow + its two local errors). */
export const conditionalEscrowErrorsAbi = [
  { type: "error", name: "NotPayer", inputs: [{ name: "caller", type: "address" }, { name: "payer", type: "address" }] },
  { type: "error", name: "DealIdMismatch", inputs: [{ name: "provided", type: "bytes32" }, { name: "expected", type: "bytes32" }] },
  { type: "error", name: "EscrowNotController", inputs: [{ name: "appId", type: "bytes32" }] },
  { type: "error", name: "DealUnderfunded", inputs: [{ name: "dealId", type: "bytes32" }, { name: "balance", type: "uint256" }, { name: "amount", type: "uint256" }] },
  { type: "error", name: "ConditionNotApproved", inputs: [{ name: "condition", type: "address" }] },
  { type: "error", name: "DealAlreadyExists", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "UnknownDeal", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "WrongState", inputs: [{ name: "dealId", type: "bytes32" }, { name: "current", type: "uint8" }] },
  { type: "error", name: "NotSettled", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "RecipientNotParticipant", inputs: [{ name: "recipient", type: "address" }] },
  { type: "error", name: "AllocationSumMismatch", inputs: [{ name: "provided", type: "uint256" }, { name: "expected", type: "uint256" }] },
  { type: "error", name: "EmptyAllocation", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "NoAllocation", inputs: [{ name: "dealId", type: "bytes32" }, { name: "caller", type: "address" }] },
  { type: "error", name: "AlreadyClaimed", inputs: [{ name: "dealId", type: "bytes32" }, { name: "recipient", type: "address" }] },
  { type: "error", name: "BeforeHardDeadline", inputs: [{ name: "dealId", type: "bytes32" }, { name: "nowTs", type: "uint256" }, { name: "deadline", type: "uint256" }] },
  { type: "error", name: "NotGovernor", inputs: [{ name: "caller", type: "address" }] },
  { type: "error", name: "NothingToSweep", inputs: [{ name: "appId", type: "bytes32" }, { name: "account", type: "bytes32" }] },
  { type: "error", name: "AllocationLengthMismatch", inputs: [{ name: "recipients", type: "uint256" }, { name: "amounts", type: "uint256" }] },
  { type: "error", name: "NotDealParticipant", inputs: [{ name: "dealId", type: "bytes32" }, { name: "caller", type: "address" }] },
] as const;

/** ConditionRegistry — governor-gated condition allowlist (D3/I9). */
export const conditionRegistryAbi = [
  { type: "function", name: "setApproved", stateMutability: "nonpayable", inputs: [{ name: "condition", type: "address" }, { name: "approved", type: "bool" }], outputs: [] },
  { type: "function", name: "isApproved", stateMutability: "view", inputs: [{ name: "condition", type: "address" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ name: "", type: "address" }] },
  { type: "event", name: "ConditionApproved", inputs: [{ name: "condition", type: "address", indexed: true }] },
  { type: "event", name: "ConditionRevoked", inputs: [{ name: "condition", type: "address", indexed: true }] },
  { type: "error", name: "ZeroAddress", inputs: [] },
] as const;

/** ConditionalEscrow — the conditional-settlement escrow over Portage core (SPEC §2.1). */
export const conditionalEscrowAbi = [
  {
    type: "function",
    name: "open",
    stateMutability: "nonpayable",
    inputs: [
      { name: "appId", type: "bytes32" },
      { name: "dealId", type: "bytes32" },
      { name: "payer", type: "address" },
      { name: "salt", type: "bytes32" },
      { name: "condition", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "hardDeadline", type: "uint256" },
      { name: "participants", type: "address[]" },
    ],
    outputs: [{ name: "", type: "bytes32" }],
  },
  { type: "function", name: "activate", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [] },
  { type: "function", name: "resolve", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [] },
  { type: "function", name: "claim", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [] },
  { type: "function", name: "refund", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [] },
  { type: "function", name: "cancel", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [] },
  { type: "function", name: "sweepUnaccounted", stateMutability: "nonpayable", inputs: [{ name: "appId", type: "bytes32" }, { name: "account", type: "bytes32" }, { name: "to", type: "address" }], outputs: [] },
  // views
  { type: "function", name: "stateOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "uint8" }] },
  { type: "function", name: "appIdOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "bytes32" }] },
  { type: "function", name: "payerOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "address" }] },
  { type: "function", name: "conditionOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "address" }] },
  { type: "function", name: "dealAmount", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "uint256" }] },
  { type: "function", name: "hardDeadlineOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "uint256" }] },
  { type: "function", name: "participantsOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "address[]" }] },
  { type: "function", name: "allocationOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "recipients", type: "address[]" }, { name: "amounts", type: "uint256[]" }] },
  { type: "function", name: "claimedOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }, { name: "recipient", type: "address" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "outstanding", stateMutability: "view", inputs: [{ name: "appId", type: "bytes32" }, { name: "account", type: "bytes32" }], outputs: [{ name: "", type: "uint256" }] },
  // events
  { type: "event", name: "DealOpened", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "appId", type: "bytes32", indexed: true }, { name: "payer", type: "address", indexed: true }, { name: "condition", type: "address", indexed: false }, { name: "amount", type: "uint256", indexed: false }] },
  { type: "event", name: "DealActivated", inputs: [{ name: "dealId", type: "bytes32", indexed: true }] },
  { type: "event", name: "DealResolved", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "recipientCount", type: "uint256", indexed: false }, { name: "totalAllocated", type: "uint256", indexed: false }] },
  { type: "event", name: "AllocationClaimed", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "recipient", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }] },
  { type: "event", name: "DealRefunded", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "payer", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }] },
  { type: "event", name: "DealCancelled", inputs: [{ name: "dealId", type: "bytes32", indexed: true }] },
  { type: "event", name: "CancelApproved", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "participant", type: "address", indexed: true }] },
  { type: "event", name: "Swept", inputs: [{ name: "appId", type: "bytes32", indexed: true }, { name: "account", type: "bytes32", indexed: true }, { name: "to", type: "address", indexed: true }, { name: "amount", type: "uint256", indexed: false }] },
  ...conditionalEscrowErrorsAbi,
] as const;

/** Common condition errors (allocation validation + not-open guard), shared by several conditions. */
const conditionCommonErrorsAbi = [
  { type: "error", name: "DealNotOpen", inputs: [{ name: "dealId", type: "bytes32" }, { name: "state", type: "uint8" }] },
  { type: "error", name: "EmptyAllocation", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "AllocationLengthMismatch", inputs: [{ name: "recipients", type: "uint256" }, { name: "amounts", type: "uint256" }] },
  { type: "error", name: "RecipientNotParticipant", inputs: [{ name: "dealId", type: "bytes32" }, { name: "recipient", type: "address" }] },
  { type: "error", name: "AllocationSumMismatch", inputs: [{ name: "dealId", type: "bytes32" }, { name: "provided", type: "uint256" }, { name: "expected", type: "uint256" }] },
] as const;

/** Shared resolve() shape returned by every ISettlementCondition. */
const conditionResolveAbi = {
  type: "function",
  name: "resolve",
  stateMutability: "view",
  inputs: [{ name: "dealId", type: "bytes32" }],
  outputs: [{ name: "settled", type: "bool" }, { name: "recipients", type: "address[]" }, { name: "amounts", type: "uint256[]" }],
} as const;

/** MutualReleaseCondition — unanimous sign-off on an allocation (SPEC §10.6). */
export const mutualReleaseConditionAbi = [
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }, { name: "recipients", type: "address[]" }, { name: "amounts", type: "uint256[]" }], outputs: [] },
  conditionResolveAbi,
  { type: "function", name: "finalized", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "approvalCount", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }, { name: "allocationHash", type: "bytes32" }], outputs: [{ name: "", type: "uint256" }] },
  { type: "event", name: "AllocationApproved", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "party", type: "address", indexed: true }, { name: "allocationHash", type: "bytes32", indexed: true }] },
  { type: "event", name: "AllocationFinalized", inputs: [{ name: "dealId", type: "bytes32", indexed: false }, { name: "allocationHash", type: "bytes32", indexed: false }] },
  { type: "error", name: "NotDealParty", inputs: [{ name: "dealId", type: "bytes32" }, { name: "caller", type: "address" }] },
  { type: "error", name: "AlreadyFinalized", inputs: [{ name: "dealId", type: "bytes32" }] },
  ...conditionCommonErrorsAbi,
] as const;

/** TimelockCondition — resolves at a soft deadline with no objection (SPEC §10.7). */
export const timelockConditionAbi = [
  { type: "function", name: "initialize", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }, { name: "softDeadline", type: "uint64" }, { name: "recipients", type: "address[]" }, { name: "amounts", type: "uint256[]" }], outputs: [] },
  { type: "function", name: "object", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [] },
  conditionResolveAbi,
  { type: "function", name: "isInitialized", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "isObjected", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "softDeadlineOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "uint64" }] },
  { type: "event", name: "Initialized", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "payer", type: "address", indexed: true }, { name: "softDeadline", type: "uint64", indexed: false }] },
  { type: "event", name: "Objected", inputs: [{ name: "dealId", type: "bytes32", indexed: true }] },
  { type: "error", name: "NotPayer", inputs: [{ name: "dealId", type: "bytes32" }, { name: "caller", type: "address" }] },
  { type: "error", name: "AlreadyInitialized", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "NotInitialized", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "AlreadyObjected", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "ObjectionWindowClosed", inputs: [{ name: "dealId", type: "bytes32" }, { name: "nowTs", type: "uint256" }, { name: "softDeadline", type: "uint64" }] },
  { type: "error", name: "SoftDeadlineNotBeforeHard", inputs: [{ name: "softDeadline", type: "uint64" }, { name: "hardDeadline", type: "uint256" }] },
  ...conditionCommonErrorsAbi,
] as const;

/** AttestationCondition — a designated attester signs off (SPEC §10.8). */
export const attestationConditionAbi = [
  { type: "function", name: "initialize", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }, { name: "attester", type: "address" }], outputs: [] },
  { type: "function", name: "attest", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }, { name: "recipients", type: "address[]" }, { name: "amounts", type: "uint256[]" }], outputs: [] },
  conditionResolveAbi,
  { type: "function", name: "isInitialized", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "isAttested", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "attesterOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "address" }] },
  { type: "event", name: "Initialized", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "attester", type: "address", indexed: true }] },
  { type: "event", name: "Attested", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "attester", type: "address", indexed: true }] },
  { type: "error", name: "NotPayer", inputs: [{ name: "dealId", type: "bytes32" }, { name: "caller", type: "address" }] },
  { type: "error", name: "NotAttester", inputs: [{ name: "dealId", type: "bytes32" }, { name: "caller", type: "address" }] },
  { type: "error", name: "AlreadyInitialized", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "NotInitialized", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "AlreadyAttested", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "ZeroAddress", inputs: [] },
  ...conditionCommonErrorsAbi,
] as const;

/** VerdictCondition — resolves from an on-chain Arena verdict (SPEC §10.9). */
export const verdictConditionAbi = [
  { type: "function", name: "initialize", stateMutability: "nonpayable", inputs: [{ name: "dealId", type: "bytes32" }, { name: "arena", type: "address" }], outputs: [] },
  conditionResolveAbi,
  { type: "function", name: "initialized", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "bool" }] },
  { type: "function", name: "arenaOf", stateMutability: "view", inputs: [{ name: "dealId", type: "bytes32" }], outputs: [{ name: "", type: "address" }] },
  { type: "event", name: "Initialized", inputs: [{ name: "dealId", type: "bytes32", indexed: true }, { name: "arena", type: "address", indexed: true }] },
  { type: "error", name: "NotPayer", inputs: [{ name: "dealId", type: "bytes32" }, { name: "caller", type: "address" }] },
  { type: "error", name: "AlreadyInitialized", inputs: [{ name: "dealId", type: "bytes32" }] },
  { type: "error", name: "ZeroAddress", inputs: [] },
  { type: "error", name: "DealNotOpen", inputs: [{ name: "dealId", type: "bytes32" }, { name: "state", type: "uint8" }] },
] as const;
