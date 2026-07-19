// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {PayoutEngine} from "../../contracts/core/PayoutEngine.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {AppRegistry} from "../../contracts/core/AppRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Fuzzing handler that drives payouts through the *real* PayoutEngine authorization
///         path. It is the creditor (funds the Ledger), the payout controller of every test
///         app (calls PayoutEngine), and the app owner (toggles pause). Ghost accounting mirrors
///         the expected state so invariants can detect any leakage or over-payment.
contract PayoutEngineHandler is CommonBase, StdUtils {
    PayoutEngine public immutable engine;
    Ledger public immutable ledger;
    AppRegistry public immutable registry;
    MockUSDC public immutable usdc;

    bytes32[] public apps;
    bytes32[] public accounts;

    uint256 public ghostCustody;
    mapping(bytes32 => uint256) public ghostAppTotal;
    mapping(bytes32 => mapping(bytes32 => uint256)) public ghostBalance;
    uint256 public ghostTotalCredited;
    uint256 public ghostTotalPaid;
    uint256 public ghostSuccessfulPayouts;

    uint256 private _nonce;

    constructor(
        PayoutEngine engine_,
        Ledger ledger_,
        AppRegistry registry_,
        MockUSDC usdc_,
        bytes32[] memory apps_,
        bytes32[] memory accounts_
    ) {
        engine = engine_;
        ledger = ledger_;
        registry = registry_;
        usdc = usdc_;
        apps = apps_;
        accounts = accounts_;
        usdc.approve(address(ledger), type(uint256).max);
    }

    function _pick(bytes32[] storage arr, uint256 seed) private view returns (bytes32) {
        return arr[seed % arr.length];
    }

    /// Consolidate funds (as creditor) into an app sub-account.
    function credit(uint256 appSeed, uint256 acctSeed, uint256 amount) external {
        bytes32 appId = _pick(apps, appSeed);
        bytes32 account = _pick(accounts, acctSeed);
        amount = bound(amount, 1, 1_000_000e6);

        usdc.mint(address(this), amount);
        ledger.credit(appId, account, amount, keccak256(abi.encode("c", _nonce++)));

        ghostBalance[appId][account] += amount;
        ghostAppTotal[appId] += amount;
        ghostCustody += amount;
        ghostTotalCredited += amount;
    }

    /// Single payout via the PayoutEngine (as the app's controller). Uses a unique referenceId
    /// each time so it exercises the success path; skips if paused/empty.
    function payout(uint256 appSeed, uint256 acctSeed, uint256 amount, address to) external {
        bytes32 appId = _pick(apps, appSeed);
        bytes32 account = _pick(accounts, acctSeed);

        if (registry.isPaused(appId)) return;
        uint256 available = ledger.balanceOf(appId, account);
        if (available == 0) return;
        if (to == address(0)) to = address(0xBEEF);
        amount = bound(amount, 1, available);

        engine.payout(appId, account, keccak256(abi.encode("p", _nonce++)), to, amount);

        ghostBalance[appId][account] -= amount;
        ghostAppTotal[appId] -= amount;
        ghostCustody -= amount;
        ghostTotalPaid += amount;
        ghostSuccessfulPayouts++;
    }

    /// Batch distribute of two recipients via the PayoutEngine.
    function distribute(uint256 appSeed, uint256 acctSeed, uint256 a1, uint256 a2, address t1, address t2) external {
        bytes32 appId = _pick(apps, appSeed);
        bytes32 account = _pick(accounts, acctSeed);

        if (registry.isPaused(appId)) return;
        uint256 available = ledger.balanceOf(appId, account);
        if (available < 2) return;
        if (t1 == address(0)) t1 = address(0xBEE1);
        if (t2 == address(0)) t2 = address(0xBEE2);

        a1 = bound(a1, 1, available - 1);
        a2 = bound(a2, 1, available - a1);

        address[] memory to = new address[](2);
        to[0] = t1;
        to[1] = t2;
        uint256[] memory amt = new uint256[](2);
        amt[0] = a1;
        amt[1] = a2;

        engine.distribute(appId, account, keccak256(abi.encode("d", _nonce++)), to, amt);

        uint256 total = a1 + a2;
        ghostBalance[appId][account] -= total;
        ghostAppTotal[appId] -= total;
        ghostCustody -= total;
        ghostTotalPaid += total;
        ghostSuccessfulPayouts++;
    }

    /// Toggle an app's pause (we are the app owner).
    function togglePause(uint256 appSeed, bool paused) external {
        registry.setAppPaused(_pick(apps, appSeed), paused);
    }
}
