// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AppRegistry} from "../contracts/core/AppRegistry.sol";
import {Ledger} from "../contracts/core/Ledger.sol";
import {PayoutEngine} from "../contracts/core/PayoutEngine.sol";
import {PortageRouter} from "../contracts/periphery/PortageRouter.sol";
import {PortageMintForwarder} from "../contracts/periphery/PortageMintForwarder.sol";

/// @title Deploy
/// @notice Deploys the Portage v0.1 stack on Arc Testnet in dependency order and wires it:
///         creditor = Router, debitor = PayoutEngine, Router.forwarder = Forwarder.
///
/// @dev Run from a SEPARATE terminal (see CLAUDE.md — Arc + keystore need a real TTY):
///
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url "$ARC_RPC_URL" \
///     --account deployer \
///     --broadcast --skip-simulation --slow -vvvv
///
///      Config via env (all optional except where noted):
///        PORTAGE_USDC           default = Arc Testnet native USDC 0x3600…0000
///        PORTAGE_GATEWAY_MINTER default = Arc Testnet GatewayMinter 0x0022…475B
///        PORTAGE_GOVERNOR       default = the deployer (broadcaster). If set to a multisig
///                               DIFFERENT from the deployer, the script deploys but SKIPS
///                               wiring (only the governor can wire) and prints the calls to make.
///        PORTAGE_GUARDIAN       default = unset (no guardian configured)
contract Deploy is Script {
    // Circle Arc Testnet (domain 26, chainId 5042002) — verified against docs.arc.io / gateway-api.
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant ARC_GATEWAY_MINTER = 0x0022222ABE238Cc2C7Bb1f21003F0a260052475B;

    struct Deployment {
        AppRegistry registry;
        Ledger ledger;
        PayoutEngine engine;
        PortageRouter router;
        PortageMintForwarder forwarder;
        address governor;
        bool wired;
    }

    function run() external returns (Deployment memory d) {
        address usdc = vm.envOr("PORTAGE_USDC", ARC_USDC);
        address gatewayMinter = vm.envOr("PORTAGE_GATEWAY_MINTER", ARC_GATEWAY_MINTER);
        address governorCfg = vm.envOr("PORTAGE_GOVERNOR", address(0));
        address guardian = vm.envOr("PORTAGE_GUARDIAN", address(0));

        vm.startBroadcast();

        address deployer = msg.sender;
        address governor = governorCfg == address(0) ? deployer : governorCfg;

        // 1-5: deploy in dependency order.
        AppRegistry registry = new AppRegistry(governor);
        Ledger ledger = new Ledger(governor, usdc, address(registry));
        PayoutEngine engine = new PayoutEngine(address(registry), address(ledger));
        PortageRouter router = new PortageRouter(governor, usdc, address(ledger), address(registry));
        PortageMintForwarder forwarder = new PortageMintForwarder(usdc, gatewayMinter, address(router));

        // 6: wire — only possible when the deployer is the governor (owner of Ledger/Router).
        bool wired = false;
        if (governor == deployer) {
            ledger.setCreditor(address(router)); // Router is the sole creditor
            ledger.setDebitor(address(engine)); // PayoutEngine is the sole debitor
            router.setForwarder(address(forwarder)); // only the Forwarder may credit the Router
            if (guardian != address(0)) registry.setGuardian(guardian);
            wired = true;
        }

        vm.stopBroadcast();

        d = Deployment(registry, ledger, engine, router, forwarder, governor, wired);
        _report(d, usdc, gatewayMinter, guardian);
    }

    function _report(Deployment memory d, address usdc, address gatewayMinter, address guardian) internal pure {
        console2.log("=========== Portage v0.1 deployment ===========");
        console2.log("USDC:            ", usdc);
        console2.log("GatewayMinter:   ", gatewayMinter);
        console2.log("Governor:        ", d.governor);
        console2.log("-----------------------------------------------");
        console2.log("AppRegistry:     ", address(d.registry));
        console2.log("Ledger:          ", address(d.ledger));
        console2.log("PayoutEngine:    ", address(d.engine));
        console2.log("PortageRouter:   ", address(d.router));
        console2.log("MintForwarder:   ", address(d.forwarder));
        console2.log("-----------------------------------------------");

        if (d.wired) {
            console2.log("Wiring: DONE (creditor=Router, debitor=PayoutEngine, forwarder set)");
            if (guardian != address(0)) console2.log("Guardian set:    ", guardian);
        } else {
            console2.log("Wiring: SKIPPED - governor != deployer. Governor must call:");
            console2.log("  ledger.setCreditor(router)");
            console2.log("  ledger.setDebitor(engine)");
            console2.log("  router.setForwarder(forwarder)");
        }
        console2.log("Next: registry.registerApp(appId, appOwner, payoutController) per integration.");
        console2.log("===============================================");
    }
}
