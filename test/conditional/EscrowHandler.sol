// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {AppRegistry} from "../../contracts/core/AppRegistry.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {PayoutEngine} from "../../contracts/core/PayoutEngine.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ConditionRegistry} from "../../contracts/conditions/ConditionRegistry.sol";
import {ConditionalEscrow} from "../../contracts/conditions/ConditionalEscrow.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";
import {MockSettlementCondition} from "./mocks/MockSettlementCondition.sol";

/// @notice Fuzzing handler for the conditional-settlement invariants (I1, I2, I4, I20).
///         Mirrors the shape of {LedgerHandler} in test/invariant/ exactly: a dedicated handler
///         that drives randomized lifecycle transitions, wired via `targetSelector`/
///         `targetContract`, with the `invariant_` assertions living in the test contract.
///
/// @dev The handler is the deals' `payer` (it calls `open` directly, so `msg.sender == payer`
///      and the D10 payer-committed `dealId` holds) and the Ledger's `creditor` stand-in
///      (in production the sole creditor is `PortageRouter` — SPEC §2.1b). The Ledger's
///      `debitor` is the REAL `PayoutEngine`, exactly as in production, so `claim`/`refund`
///      exercise the true payout path once implemented.
///
///      Every entry point below reverts against the `ConditionalEscrow`/`ConditionRegistry`
///      stubs (`NotImplemented()`). With `fail_on_revert = false` (foundry.toml [invariant])
///      those reverts are skipped, leaving genesis state — the redness of the suite comes from
///      the `invariant_` functions themselves reading escrow views that revert on the stub.
contract EscrowHandler is CommonBase, StdUtils, StdCheats {
    Ledger public immutable ledger;
    AppRegistry public immutable registry;
    PayoutEngine public immutable engine;
    ConditionRegistry public immutable condReg;
    ConditionalEscrow public immutable escrow;
    MockSettlementCondition public immutable cond;
    MockUSDC public immutable usdc;

    address public immutable governor;
    address public immutable participantA;
    address public immutable participantB;

    bytes32 public immutable escrowApp;
    uint256 public constant DEAL_AMOUNT = 100e6;
    uint256 public immutable hardDeadline;

    // The fixed, enumerable candidate deal set. Every dealId the handler can ever open is one of
    // these (derived from a fixed salt set at construction), so the invariants can iterate the
    // full account space — the same trick {LedgerHandler} uses with its fixed `accounts` array.
    bytes32[] public salts;
    bytes32[] public dealIds;

    // Ghost accounting (independent of the escrow's own state), used by I4.
    mapping(bytes32 dealId => uint256) public ghostClaimed; // Σ amounts this deal has paid out

    uint256 private _nonce;

    constructor(
        Ledger ledger_,
        AppRegistry registry_,
        PayoutEngine engine_,
        ConditionRegistry condReg_,
        ConditionalEscrow escrow_,
        MockSettlementCondition cond_,
        MockUSDC usdc_,
        address governor_,
        bytes32 escrowApp_,
        address participantA_,
        address participantB_
    ) {
        ledger = ledger_;
        registry = registry_;
        engine = engine_;
        condReg = condReg_;
        escrow = escrow_;
        cond = cond_;
        usdc = usdc_;
        governor = governor_;
        escrowApp = escrowApp_;
        participantA = participantA_;
        participantB = participantB_;
        hardDeadline = block.timestamp + 3650 days; // deals never hit the deadline during a run

        salts.push(keccak256("deal-1"));
        salts.push(keccak256("deal-2"));
        salts.push(keccak256("deal-3"));
        salts.push(keccak256("deal-4"));
        for (uint256 i = 0; i < salts.length; i++) {
            dealIds.push(_computeDealId(salts[i]));
        }

        // The handler is the creditor stand-in; pre-approve the Ledger to pull USDC.
        usdc.approve(address(ledger), type(uint256).max);
    }

    function dealsLength() external view returns (uint256) {
        return dealIds.length;
    }

    function _computeDealId(bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), salt, address(cond), DEAL_AMOUNT, hardDeadline));
    }

    function _participants() internal view returns (address[] memory p) {
        p = new address[](2);
        p[0] = participantA;
        p[1] = participantB;
    }

    // ---------------------------------------------------------------------
    // Fuzzed entry points
    // ---------------------------------------------------------------------

    /// Fund a candidate deal via the creditor stand-in, approve the condition, and open it.
    /// Post-implementation this establishes `outstanding == DEAL_AMOUNT` for the deal.
    function openDeal(uint256 saltSeed) external {
        bytes32 salt = salts[saltSeed % salts.length];
        bytes32 dealId = _computeDealId(salt);

        // Simulate a Gateway deposit landing on (escrowApp, dealId): creditor -> Ledger.credit.
        usdc.mint(address(this), DEAL_AMOUNT);
        ledger.credit(escrowApp, dealId, DEAL_AMOUNT, keccak256(abi.encode("gw", dealId, _nonce++)));

        // Governor approves the (single, shared) condition in the registry (I9). Idempotent.
        vm.prank(governor);
        condReg.setApproved(address(cond), true);

        // The handler is the payer (msg.sender == payer, D10 dealId commits to it).
        escrow.open(escrowApp, dealId, address(this), salt, address(cond), DEAL_AMOUNT, hardDeadline, _participants());
    }

    /// Snapshot a valid, participant-only allocation (splits DEAL_AMOUNT across A and B).
    function resolveDeal(uint256 dealSeed, uint256 splitSeed) external {
        bytes32 dealId = dealIds[dealSeed % dealIds.length];
        if (escrow.stateOf(dealId) != IConditionalEscrow.State.Funded) return;

        uint256 toA = bound(splitSeed, 1, DEAL_AMOUNT - 1);
        address[] memory p = _participants();
        uint256[] memory amts = new uint256[](2);
        amts[0] = toA;
        amts[1] = DEAL_AMOUNT - toA; // exact-sum (I2 happy path); recipients ⊆ participants (I11)
        cond.setOutcome(true, p, amts);

        escrow.resolve(dealId);
    }

    /// Claim one resolved recipient's allocation (as that recipient). One-shot per recipient (I4).
    function claimDeal(uint256 dealSeed, uint256 recipSeed) external {
        bytes32 dealId = dealIds[dealSeed % dealIds.length];
        IConditionalEscrow.State s = escrow.stateOf(dealId);
        if (s != IConditionalEscrow.State.Resolved) return;

        (address[] memory r, uint256[] memory a) = escrow.allocationOf(dealId);
        if (r.length == 0) return;
        uint256 idx = recipSeed % r.length;
        if (escrow.claimedOf(dealId, r[idx])) return;

        vm.prank(r[idx]);
        escrow.claim(dealId);
        ghostClaimed[dealId] += a[idx];
    }

    /// A late credit to an already-open deal — unaccounted surplus (D11), never a top-up.
    function creditSurplus(uint256 dealSeed, uint256 amount) external {
        bytes32 dealId = dealIds[dealSeed % dealIds.length];
        if (escrow.stateOf(dealId) == IConditionalEscrow.State.None) return;
        amount = bound(amount, 1, 10_000e6);
        usdc.mint(address(this), amount);
        ledger.credit(escrowApp, dealId, amount, keccak256(abi.encode("surplus", dealId, _nonce++)));
    }

    /// Governor sweeps unaccounted surplus for a deal (D12). Must never touch principal (I20).
    function sweepSurplus(uint256 dealSeed, address to) external {
        bytes32 dealId = dealIds[dealSeed % dealIds.length];
        if (to == address(0)) to = address(0xBEEF);
        vm.prank(governor);
        escrow.sweepUnaccounted(escrowApp, dealId, to);
    }
}
