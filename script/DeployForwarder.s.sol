// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PortageRouter} from "../contracts/periphery/PortageRouter.sol";
import {PortageMintForwarder} from "../contracts/periphery/PortageMintForwarder.sol";

/// @title DeployForwarder
/// @notice Redeploys ONLY the PortageMintForwarder (e.g. after the B1 change added
///         executeMintWithMeta / hashMetaBinding / EIP712) and re-wires the existing Router to
///         point at the new forwarder. The Core (AppRegistry, Ledger, PayoutEngine) and the
///         Router are unchanged and are NOT redeployed — the Router's `credit(bytes,uint256,
///         bytes32)` selector/ABI is identical, so it works with the new forwarder as-is.
///
/// @dev The deployer must be the Router's owner (the governor), so it can call setForwarder in the
///      same broadcast. Run in a SEPARATE terminal (keystore/TTY):
///
///   forge script script/DeployForwarder.s.sol:DeployForwarder \
///     --rpc-url "$ARC_RPC_URL" \
///     --account deployer \
///     --broadcast --skip-simulation --slow -vvvv
///
///      Env overrides (defaults = Arc Testnet v0.1 deployment):
///        PORTAGE_ROUTER          existing PortageRouter to re-wire (default below)
///        PORTAGE_USDC            default = Arc native USDC 0x3600…0000
///        PORTAGE_GATEWAY_MINTER  default = Arc GatewayMinter 0x0022…475B
contract DeployForwarder is Script {
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant ARC_GATEWAY_MINTER = 0x0022222ABE238Cc2C7Bb1f21003F0a260052475B;
    address internal constant DEPLOYED_ROUTER = 0x9eacb164e5B9D3D24b1A87437668B2245169eD4B;

    function run() external returns (PortageMintForwarder forwarder) {
        address usdc = vm.envOr("PORTAGE_USDC", ARC_USDC);
        address gatewayMinter = vm.envOr("PORTAGE_GATEWAY_MINTER", ARC_GATEWAY_MINTER);
        address router = vm.envOr("PORTAGE_ROUTER", DEPLOYED_ROUTER);

        vm.startBroadcast();

        // 1. Deploy the new forwarder (no USDC interaction in its constructor).
        forwarder = new PortageMintForwarder(usdc, gatewayMinter, router);

        // 2. Re-wire the Router to accept credits only from the new forwarder.
        //    Requires msg.sender == Router.owner() (the governor / deployer).
        PortageRouter(router).setForwarder(address(forwarder));

        vm.stopBroadcast();

        console2.log("=========== Portage forwarder redeploy ===========");
        console2.log("Router (unchanged):     ", router);
        console2.log("NEW PortageMintForwarder:", address(forwarder));
        console2.log("Router.setForwarder ->  ", address(forwarder));
        console2.log("Update SDK config PORTAGE_ARC_TESTNET.mintForwarder + CLAUDE.md with this address.");
        console2.log("==================================================");
    }
}
