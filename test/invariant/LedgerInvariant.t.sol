// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {AppRegistry} from "../../contracts/core/AppRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {LedgerHandler} from "./LedgerHandler.sol";

/// @notice Invariant suite for the Ledger accounting core. Asserts the four properties from
///         ARCHITECTURE.md §7 across randomized credit/debit/pause sequences.
contract LedgerInvariantTest is Test {
    Ledger ledger;
    AppRegistry registry;
    MockUSDC usdc;
    LedgerHandler handler;

    bytes32[] apps;
    bytes32[] accounts;

    function setUp() public {
        usdc = new MockUSDC();
        // This test contract is the governor of both Core contracts.
        registry = new AppRegistry(address(this));
        ledger = new Ledger(address(this), address(usdc), address(registry));

        apps.push(keccak256("coliseum"));
        apps.push(keccak256("basedrop"));
        apps.push(keccak256("tipping"));

        accounts.push(keccak256("acct-a"));
        accounts.push(keccak256("acct-b"));
        accounts.push(keccak256("acct-c"));
        accounts.push(keccak256("acct-d"));

        handler = new LedgerHandler(ledger, registry, usdc, apps, accounts);

        // Wire the handler as the sole creditor and debitor.
        ledger.setCreditor(address(handler));
        ledger.setDebitor(address(handler));

        // Register every app with the handler as owner (so it can toggle pause).
        for (uint256 i = 0; i < apps.length; i++) {
            registry.registerApp(apps[i], address(handler), address(handler));
        }

        // Only fuzz the handler's entrypoints.
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.credit.selector;
        selectors[1] = handler.debit.selector;
        selectors[2] = handler.togglePause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// I1: the vault is always solvent for what it owes apps.
    function invariant_solvency() public view {
        assertGe(usdc.balanceOf(address(ledger)), ledger.custodyTotal());
    }

    /// I2: custodyTotal equals the sum of every app's total, and matches the ghost mirror.
    function invariant_custodyEqualsSumOfApps() public view {
        uint256 sum;
        for (uint256 i = 0; i < apps.length; i++) {
            sum += ledger.appBalance(apps[i]);
        }
        assertEq(ledger.custodyTotal(), sum);
        assertEq(ledger.custodyTotal(), handler.ghostCustody());
    }

    /// I3: each app's total equals the sum of its account balances (and its ghost mirror).
    function invariant_appTotalEqualsSumOfAccounts() public view {
        for (uint256 i = 0; i < apps.length; i++) {
            bytes32 appId = apps[i];
            uint256 sum;
            for (uint256 j = 0; j < accounts.length; j++) {
                sum += ledger.balanceOf(appId, accounts[j]);
            }
            assertEq(ledger.appBalance(appId), sum);
            assertEq(ledger.appBalance(appId), handler.ghostAppTotal(appId));
        }
    }

    /// I4 (isolation): every individual balance equals its independently tracked ghost value.
    ///     If any cross-app leakage occurred, a ghost would diverge from the ledger.
    function invariant_perAccountMatchesGhost() public view {
        for (uint256 i = 0; i < apps.length; i++) {
            for (uint256 j = 0; j < accounts.length; j++) {
                assertEq(ledger.balanceOf(apps[i], accounts[j]), handler.ghostBalance(apps[i], accounts[j]));
            }
        }
    }

    /// Lifetime counters reconcile: Σ credited − Σ paid == custodyTotal.
    function invariant_lifetimeCountersReconcile() public view {
        assertEq(handler.ghostTotalCredited() - handler.ghostTotalPaid(), ledger.custodyTotal());
    }
}
