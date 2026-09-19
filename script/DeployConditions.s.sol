// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AppRegistry} from "../contracts/core/AppRegistry.sol";
import {ConditionRegistry} from "../contracts/conditions/ConditionRegistry.sol";
import {ConditionalEscrow} from "../contracts/conditions/ConditionalEscrow.sol";
import {MutualReleaseCondition} from "../contracts/conditions/MutualReleaseCondition.sol";
import {TimelockCondition} from "../contracts/conditions/TimelockCondition.sol";
import {AttestationCondition} from "../contracts/conditions/AttestationCondition.sol";
import {VerdictCondition} from "../contracts/conditions/VerdictCondition.sol";

/// @title DeployConditions
/// @notice Deploys the conditional-settlement layer (SPEC §10.11) on top of the ALREADY-DEPLOYED
///         Portage core (AppRegistry/Ledger/PayoutEngine — core is untouched, D7). Order:
///           1. ConditionRegistry(governor)
///           2. ConditionalEscrow(appRegistry, ledger, payoutEngine, conditionRegistry, governor)
///           3. the four conditions, each bound to the escrow
///         Then governor-only setup (only when the broadcaster is the governor):
///           4. AppRegistry.registerApp(ESCROW_APP, governor, escrow)   — escrow is payoutController (O3/D9)
///           5. ConditionRegistry.setApproved(condition, true) for all four conditions (I9)
///
/// @dev Run from a SEPARATE terminal (Arc + keystore need a real TTY password prompt):
///
///   forge script script/DeployConditions.s.sol:DeployConditions \
///     --rpc-url "$ARC_RPC_URL" \
///     --account deployer \
///     --broadcast --slow -vvvv
///
///      The broadcaster MUST be the existing core governor (owner of the deployed AppRegistry),
///      or step 4 (registerApp, onlyOwner) reverts. No --skip-simulation is needed: unlike core
///      Deploy, no constructor here touches native USDC at 0x3600.
///
///      Config via env (all optional; defaults = Arc Testnet v0.1 deployment):
///        PORTAGE_APP_REGISTRY    default 0xb803bF100F5CEb71dcC6Db20f8586A7A0901BB67
///        PORTAGE_LEDGER          default 0xEEc603760483B0689B76fb3780eE7edc2E1661b4
///        PORTAGE_PAYOUT_ENGINE   default 0xA9Ebe9fC146F6Bdb2FF5A688017eb496C56F66e0
///        PORTAGE_GOVERNOR        default = broadcaster; must equal the core AppRegistry owner
///        PORTAGE_ESCROW_APP_NAME default "portage-escrow-v1" (ESCROW_APP = keccak256(name))
contract DeployConditions is Script {
    // Arc Testnet v0.1 core (deployed 2026-07-20). Overridable via env for other deployments.
    address internal constant ARC_TESTNET_APP_REGISTRY = 0xb803bF100F5CEb71dcC6Db20f8586A7A0901BB67;
    address internal constant ARC_TESTNET_LEDGER = 0xEEc603760483B0689B76fb3780eE7edc2E1661b4;
    address internal constant ARC_TESTNET_PAYOUT_ENGINE = 0xA9Ebe9fC146F6Bdb2FF5A688017eb496C56F66e0;

    struct Deployment {
        ConditionRegistry conditionRegistry;
        ConditionalEscrow escrow;
        MutualReleaseCondition mutualRelease;
        TimelockCondition timelock;
        AttestationCondition attestation;
        VerdictCondition verdict;
        bytes32 escrowApp;
        address governor;
        address deployer;
        bool wired;
    }

    function run() external returns (Deployment memory d) {
        address appRegistry = vm.envOr("PORTAGE_APP_REGISTRY", ARC_TESTNET_APP_REGISTRY);
        address ledger = vm.envOr("PORTAGE_LEDGER", ARC_TESTNET_LEDGER);
        address payoutEngine = vm.envOr("PORTAGE_PAYOUT_ENGINE", ARC_TESTNET_PAYOUT_ENGINE);
        address governorCfg = vm.envOr("PORTAGE_GOVERNOR", address(0));
        bytes32 escrowApp = keccak256(bytes(vm.envOr("PORTAGE_ESCROW_APP_NAME", string("portage-escrow-v1"))));

        // The governor setup (registerApp) is onlyOwner on the EXISTING AppRegistry, so it can only
        // run in-broadcast when the broadcaster IS that owner. Read the live owner (a view call, so
        // it stays outside startBroadcast); if it reverts — e.g. a local simulation with no core
        // deployed — we skip setup rather than attempt an unauthorized registerApp.
        d.escrowApp = escrowApp;

        address coreOwner;
        bool ownerKnown;
        // Guard the code-size check: calling owner() on an address with no code (e.g. a local
        // simulation with no core deployed) would revert before try/catch could catch it.
        if (appRegistry.code.length > 0) {
            try AppRegistry(appRegistry).owner() returns (address o) {
                coreOwner = o;
                ownerKnown = true;
            } catch {}
        }

        vm.startBroadcast();

        d.deployer = msg.sender;
        // New contracts share the core governor by default (so the same account runs setup and
        // later admin), unless PORTAGE_GOVERNOR overrides it. (Written straight into `d` to keep
        // the stack shallow — many typed locals here overflow it.)
        d.governor = governorCfg != address(0) ? governorCfg : (ownerKnown ? coreOwner : d.deployer);

        // 1-3: deploy in dependency order (no external calls in any constructor).
        d.conditionRegistry = new ConditionRegistry(d.governor);
        d.escrow = new ConditionalEscrow(appRegistry, ledger, payoutEngine, address(d.conditionRegistry), d.governor);
        d.mutualRelease = new MutualReleaseCondition(address(d.escrow));
        d.timelock = new TimelockCondition(address(d.escrow));
        d.attestation = new AttestationCondition(address(d.escrow));
        d.verdict = new VerdictCondition(address(d.escrow));

        // 4-5: governor setup, in-broadcast only when the broadcaster is BOTH the core owner (for
        // registerApp) and the ConditionRegistry owner (for setApproved) — i.e. deployer is the
        // core governor. Otherwise deploy-only; the governor makes the calls afterward (see report).
        if (ownerKnown && d.deployer == coreOwner && d.governor == d.deployer) {
            // O3/D9: one call sets the escrow app's owner (governor) and payoutController (escrow).
            AppRegistry(appRegistry).registerApp(d.escrowApp, d.governor, address(d.escrow));
            // I9: allowlist all four conditions.
            d.conditionRegistry.setApproved(address(d.mutualRelease), true);
            d.conditionRegistry.setApproved(address(d.timelock), true);
            d.conditionRegistry.setApproved(address(d.attestation), true);
            d.conditionRegistry.setApproved(address(d.verdict), true);
            d.wired = true;
        }

        vm.stopBroadcast();

        _report(d, appRegistry, ledger, payoutEngine, coreOwner, ownerKnown);
    }

    function _report(
        Deployment memory d,
        address appRegistry,
        address ledger,
        address payoutEngine,
        address coreOwner,
        bool ownerKnown
    ) internal pure {
        console2.log("======= Portage conditional-settlement deployment =======");
        console2.log("Core AppRegistry:   ", appRegistry);
        console2.log("Core Ledger:        ", ledger);
        console2.log("Core PayoutEngine:  ", payoutEngine);
        console2.log("Core owner (gov):   ", ownerKnown ? coreOwner : address(0));
        console2.log("Broadcaster:        ", d.deployer);
        console2.log("New-contract gov:   ", d.governor);
        console2.log("---------------------------------------------------------");
        console2.log("ConditionRegistry:  ", address(d.conditionRegistry));
        console2.log("ConditionalEscrow:  ", address(d.escrow));
        console2.log("MutualRelease:      ", address(d.mutualRelease));
        console2.log("Timelock:           ", address(d.timelock));
        console2.log("Attestation:        ", address(d.attestation));
        console2.log("Verdict:            ", address(d.verdict));
        console2.log("Escrow appId:       ");
        console2.logBytes32(d.escrowApp);
        console2.log("---------------------------------------------------------");

        if (d.wired) {
            console2.log("Setup: DONE (broadcaster is the core governor)");
            console2.log("  registerApp(escrowApp, governor, escrow)  [escrow = payoutController]");
            console2.log("  setApproved(condition, true) x4           [MutualRelease/Timelock/Attestation/Verdict]");
        } else {
            console2.log("Setup: SKIPPED - broadcaster is NOT the core governor (see 'Core owner' above).");
            console2.log("Broadcast this script from the core governor account (--account <gov> / --sender <gov>");
            console2.log("for a dry-run), OR have the governor make these calls afterward:");
            console2.log("  AppRegistry.registerApp(escrowApp, <governor>, escrow)   [escrow = payoutController]");
            console2.log("  ConditionRegistry.setApproved(<each condition>, true)    [must own ConditionRegistry]");
        }
        console2.log("Next: populate config.ts conditions{} (PENDING -> these addresses); verify on ArcScan.");
        console2.log("=========================================================");
    }
}
