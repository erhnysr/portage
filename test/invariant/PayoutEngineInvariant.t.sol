// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PayoutEngine} from "../../contracts/core/PayoutEngine.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {AppRegistry} from "../../contracts/core/AppRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {PayoutEngineHandler} from "./PayoutEngineHandler.sol";

/// @notice Invariant suite proving that payouts driven through the real PayoutEngine
///         authorization path preserve solvency and app isolation, and never over-pay.
contract PayoutEngineInvariantTest is Test {
    PayoutEngine engine;
    Ledger ledger;
    AppRegistry registry;
    MockUSDC usdc;
    PayoutEngineHandler handler;

    bytes32[] apps;
    bytes32[] accounts;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AppRegistry(address(this));
        ledger = new Ledger(address(this), address(usdc), address(registry));
        engine = new PayoutEngine(address(registry), address(ledger));

        apps.push(keccak256("coliseum"));
        apps.push(keccak256("basedrop"));
        apps.push(keccak256("tipping"));
        accounts.push(keccak256("acct-a"));
        accounts.push(keccak256("acct-b"));
        accounts.push(keccak256("acct-c"));

        handler = new PayoutEngineHandler(engine, ledger, registry, usdc, apps, accounts);

        ledger.setCreditor(address(handler)); // handler consolidates
        ledger.setDebitor(address(engine)); // engine is the only debitor

        // Handler is both owner (pause) and payout controller of every app.
        for (uint256 i = 0; i < apps.length; i++) {
            registry.registerApp(apps[i], address(handler), address(handler));
        }

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.credit.selector;
        selectors[1] = handler.payout.selector;
        selectors[2] = handler.distribute.selector;
        selectors[3] = handler.togglePause.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Solvency: the vault always holds at least what it owes.
    function invariant_solvency() public view {
        assertGe(usdc.balanceOf(address(ledger)), ledger.custodyTotal());
    }

    /// custodyTotal == Σ app totals == ghost mirror.
    function invariant_custodyEqualsSumOfApps() public view {
        uint256 sum;
        for (uint256 i = 0; i < apps.length; i++) {
            sum += ledger.appBalance(apps[i]);
        }
        assertEq(ledger.custodyTotal(), sum);
        assertEq(ledger.custodyTotal(), handler.ghostCustody());
    }

    /// Isolation: every individual balance matches its independently tracked ghost. Payouts
    /// routed through one app's controller can never perturb another app's accounts.
    function invariant_perAccountMatchesGhost() public view {
        for (uint256 i = 0; i < apps.length; i++) {
            for (uint256 j = 0; j < accounts.length; j++) {
                assertEq(ledger.balanceOf(apps[i], accounts[j]), handler.ghostBalance(apps[i], accounts[j]));
            }
        }
    }

    /// No over-payment: Σ credited − Σ paid == custodyTotal, and per-app paid matches ghost.
    function invariant_paymentsReconcile() public view {
        assertEq(handler.ghostTotalCredited() - handler.ghostTotalPaid(), ledger.custodyTotal());

        uint256 paidSum;
        for (uint256 i = 0; i < apps.length; i++) {
            paidSum += ledger.totalPaid(apps[i]);
        }
        assertEq(paidSum, handler.ghostTotalPaid());
    }
}
