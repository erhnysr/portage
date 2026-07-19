// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {AppRegistry} from "../../contracts/core/AppRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Fuzzing handler for the Ledger invariants. Acts as both creditor and debitor
///         (and as the owner of every test app, so it can toggle pause). Maintains ghost
///         accounting mirrored against the Ledger's own state.
contract LedgerHandler is CommonBase, StdUtils {
    Ledger public immutable ledger;
    AppRegistry public immutable registry;
    MockUSDC public immutable usdc;

    bytes32[] public apps;
    bytes32[] public accounts;

    // Ghost accounting (independent recomputation of what the Ledger should hold).
    uint256 public ghostCustody;
    mapping(bytes32 appId => uint256) public ghostAppTotal;
    mapping(bytes32 appId => mapping(bytes32 account => uint256)) public ghostBalance;

    uint256 public ghostTotalCredited;
    uint256 public ghostTotalPaid;

    uint256 private _nonce;

    constructor(Ledger ledger_, AppRegistry registry_, MockUSDC usdc_, bytes32[] memory apps_, bytes32[] memory accounts_) {
        ledger = ledger_;
        registry = registry_;
        usdc = usdc_;
        apps = apps_;
        accounts = accounts_;

        // Pre-approve the Ledger to pull USDC from this handler (the creditor).
        usdc.approve(address(ledger), type(uint256).max);
    }

    function appsLength() external view returns (uint256) {
        return apps.length;
    }

    function accountsLength() external view returns (uint256) {
        return accounts.length;
    }

    function _pick(bytes32[] storage arr, uint256 seed) private view returns (bytes32) {
        return arr[seed % arr.length];
    }

    /// Fuzz: consolidate funds into an app sub-account.
    function credit(uint256 appSeed, uint256 acctSeed, uint256 amount) external {
        bytes32 appId = _pick(apps, appSeed);
        bytes32 account = _pick(accounts, acctSeed);
        amount = bound(amount, 1, 1_000_000e6);

        // Mint the backing USDC to ourselves (simulating a fresh Gateway mint to the router).
        usdc.mint(address(this), amount);

        bytes32 transferId = keccak256(abi.encode("credit", _nonce++));
        ledger.credit(appId, account, amount, transferId);

        ghostBalance[appId][account] += amount;
        ghostAppTotal[appId] += amount;
        ghostCustody += amount;
        ghostTotalCredited += amount;
    }

    /// Fuzz: pay out from an app sub-account (bounded to available; skips if paused/empty).
    function debit(uint256 appSeed, uint256 acctSeed, uint256 amount, address to) external {
        bytes32 appId = _pick(apps, appSeed);
        bytes32 account = _pick(accounts, acctSeed);

        if (registry.isPaused(appId)) return;
        uint256 available = ledger.balanceOf(appId, account);
        if (available == 0) return;
        if (to == address(0)) to = address(0xBEEF);
        amount = bound(amount, 1, available);

        ledger.debit(appId, account, amount, to);

        ghostBalance[appId][account] -= amount;
        ghostAppTotal[appId] -= amount;
        ghostCustody -= amount;
        ghostTotalPaid += amount;
    }

    /// Fuzz: toggle an app's pause state (we are the app owner in the invariant setup).
    function togglePause(uint256 appSeed, bool paused) external {
        bytes32 appId = _pick(apps, appSeed);
        registry.setAppPaused(appId, paused);
    }
}
