// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AppRegistry} from "../../contracts/core/AppRegistry.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {PayoutEngine} from "../../contracts/core/PayoutEngine.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ConditionRegistry} from "../../contracts/conditions/ConditionRegistry.sol";
import {ConditionalEscrow} from "../../contracts/conditions/ConditionalEscrow.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";
import {MockSettlementCondition} from "./mocks/MockSettlementCondition.sol";
import {EscrowHandler} from "./EscrowHandler.sol";

/// @notice Stateful Foundry invariant suite for the conditional-settlement layer, covering the
///         four properties the SPEC (§5) calls out as solvency/single-settlement cornerstones —
///         I1, I2, I4, I20 — across randomized open/resolve/claim/credit/sweep sequences.
///
///         Structure follows test/invariant/LedgerInvariant.t.sol verbatim: deploy REAL Portage
///         core (AppRegistry, Ledger, PayoutEngine) + the escrow layer, wire a single
///         {EscrowHandler} as creditor stand-in and payer, restrict fuzzing to its entry points
///         via `targetSelector`/`targetContract`, and put the `invariant_` assertions here.
///
/// @dev Failing-first: `ConditionalEscrow`/`ConditionRegistry` are stubs that revert
///      `NotImplemented()`. With `fail_on_revert = false` the handler's reverting calls are
///      skipped, so no deals are ever created; each `invariant_` below therefore goes red
///      because it reads an escrow view (`outstanding`, `stateOf`, `dealAmount`) that reverts
///      on the stub. Once the escrow is implemented these reads return real state and the
///      properties are genuinely checked.
contract EscrowStatefulInvariantsTest is Test {
    AppRegistry internal registry;
    Ledger internal ledger;
    PayoutEngine internal engine;
    ConditionRegistry internal condReg;
    ConditionalEscrow internal escrow;
    MockSettlementCondition internal cond;
    MockUSDC internal usdc;
    EscrowHandler internal handler;

    address internal governor = makeAddr("governor");
    address internal appOwner = makeAddr("appOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant ESCROW_APP = keccak256("portage-escrow-v1");

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AppRegistry(governor);
        ledger = new Ledger(governor, address(usdc), address(registry));
        engine = new PayoutEngine(address(registry), address(ledger));
        condReg = new ConditionRegistry(governor);
        escrow = new ConditionalEscrow(
            address(registry), address(ledger), address(engine), address(condReg), governor
        );
        cond = new MockSettlementCondition();

        handler = new EscrowHandler(
            ledger, registry, engine, condReg, escrow, cond, usdc, governor, ESCROW_APP, alice, bob
        );

        vm.startPrank(governor);
        // Creditor stand-in: the handler seeds Ledger balances directly, simulating a completed
        // Gateway deposit (PortageRouter -> Ledger.credit). In production the sole creditor is
        // PortageRouter (SPEC §2.1b — a single creditor slot). Debitor is the REAL PayoutEngine,
        // exactly as in production, so the escrow's claim/refund path is exercised for real.
        ledger.setCreditor(address(handler));
        ledger.setDebitor(address(engine));
        // O3: one governor action wires the escrow as the app's payout controller.
        registry.registerApp(ESCROW_APP, appOwner, address(escrow));
        vm.stopPrank();

        // Only fuzz the handler's lifecycle entry points.
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.openDeal.selector;
        selectors[1] = handler.resolveDeal.selector;
        selectors[2] = handler.claimDeal.selector;
        selectors[3] = handler.creditSurplus.selector;
        selectors[4] = handler.sweepSurplus.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// I1: `Ledger.appBalance(appId) >= Σ outstanding[appId][account]` over all accounts.
    ///     Inequality, not equality — unaccounted surplus (D11) may sit above the sum until
    ///     swept. No deal is ever paid out of another deal's funds.
    function invariant_I1_appBalanceGeSumOutstanding() public view {
        uint256 n = handler.dealsLength();
        uint256 sumOutstanding;
        for (uint256 i = 0; i < n; i++) {
            sumOutstanding += escrow.outstanding(ESCROW_APP, handler.dealIds(i));
        }
        assertGe(ledger.appBalance(ESCROW_APP), sumOutstanding);
    }

    /// I2: every resolved (or fully-claimed) deal's snapshotted allocation sums to exactly
    ///     `deal.amount` — not less, not more (D6 fail-closed guarantees no other resolved shape).
    function invariant_I2_resolvedAllocationSumsToDealAmount() public view {
        uint256 n = handler.dealsLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 dealId = handler.dealIds(i);
            IConditionalEscrow.State s = escrow.stateOf(dealId);
            if (s != IConditionalEscrow.State.Resolved && s != IConditionalEscrow.State.Claimed) continue;

            (, uint256[] memory amounts) = escrow.allocationOf(dealId);
            uint256 sum;
            for (uint256 j = 0; j < amounts.length; j++) {
                sum += amounts[j];
            }
            assertEq(sum, escrow.dealAmount(dealId));
        }
    }

    /// I4: the total ever claimed for a deal never exceeds `deal.amount`. A double-payout bug
    ///     would drive the handler's ghost tally above the deal amount; this catches it.
    function invariant_I4_totalClaimedNeverExceedsDealAmount() public view {
        uint256 n = handler.dealsLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 dealId = handler.dealIds(i);
            if (escrow.stateOf(dealId) == IConditionalEscrow.State.None) continue;
            assertLe(handler.ghostClaimed(dealId), escrow.dealAmount(dealId));
        }
    }

    /// I20: `sweepUnaccounted` can never reduce `ledger.balanceOf(appId, account)` below
    ///     `outstanding[appId][account]`, in any state (including mid-claim on a partially
    ///     claimed deal). Asserted here after every fuzzed sweep/claim/credit sequence.
    function invariant_I20_balanceNeverBelowOutstanding() public view {
        uint256 n = handler.dealsLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 dealId = handler.dealIds(i);
            assertGe(ledger.balanceOf(ESCROW_APP, dealId), escrow.outstanding(ESCROW_APP, dealId));
        }
    }
}
