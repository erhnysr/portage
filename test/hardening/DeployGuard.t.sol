// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployForwarder} from "../../script/DeployForwarder.s.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract DeployHarness is Deploy {
    function check(address minter, address governor, address guardian) external view {
        _requireMainnetConfig(minter, governor, guardian);
    }
}

contract DeployForwarderHarness is DeployForwarder {
    function resolve(address router, address minter) external view returns (address) {
        return _resolveRouter(router, minter);
    }
}

/// @notice The deploy scripts must refuse Arc mainnet (chainId 5042) unless every
///         network-specific value is set explicitly — the testnet defaults must never be used.
///         Negative cases go through harnesses (no process-wide env, so tests can run in parallel).
contract DeployGuardTest is Test {
    address constant MAINNET_MINTER = 0x2222222d7164433c4C09B0b0D809a9b52C04C205;
    address constant TESTNET_MINTER = 0x0022222ABE238Cc2C7Bb1f21003F0a260052475B;
    address constant TESTNET_ROUTER = 0x9eacb164e5B9D3D24b1A87437668B2245169eD4B;
    address constant USDC = 0x3600000000000000000000000000000000000000;

    DeployHarness deploy;
    DeployForwarderHarness fwd;
    address multisig = makeAddr("multisig");
    address guardian = makeAddr("guardian");

    function setUp() public {
        deploy = new DeployHarness();
        fwd = new DeployForwarderHarness();
        vm.chainId(5042);
    }

    function test_mainnet_rejectsTestnetMinter() public {
        vm.expectRevert(bytes("Deploy: mainnet requires the mainnet GatewayMinter"));
        deploy.check(TESTNET_MINTER, multisig, guardian);
    }

    function test_mainnet_requiresGovernor() public {
        vm.expectRevert(bytes("Deploy: mainnet requires PORTAGE_GOVERNOR (multisig)"));
        deploy.check(MAINNET_MINTER, address(0), guardian);
    }

    function test_mainnet_requiresGuardian() public {
        vm.expectRevert(bytes("Deploy: mainnet requires PORTAGE_GUARDIAN"));
        deploy.check(MAINNET_MINTER, multisig, address(0));
    }

    function test_mainnet_acceptsExplicitConfig() public view {
        deploy.check(MAINNET_MINTER, multisig, guardian);
    }

    function test_testnet_isUnchanged() public {
        vm.chainId(5042002);
        deploy.check(TESTNET_MINTER, address(0), address(0)); // testnet defaults still allowed
        assertEq(fwd.resolve(address(0), TESTNET_MINTER), TESTNET_ROUTER);
    }

    function test_forwarderScript_mainnet_requiresExplicitRouter() public {
        vm.expectRevert(bytes("DeployForwarder: mainnet requires PORTAGE_ROUTER"));
        fwd.resolve(address(0), MAINNET_MINTER);
    }

    function test_forwarderScript_mainnet_rejectsTestnetMinter() public {
        vm.expectRevert(bytes("DeployForwarder: mainnet requires the mainnet GatewayMinter"));
        fwd.resolve(makeAddr("router"), TESTNET_MINTER);
    }

    /// End-to-end: the real `run()` on chainId 5042 with explicit env deploys with the mainnet
    /// minter and leaves wiring to the multisig. The only test here that sets env vars.
    function test_mainnet_run_endToEnd() public {
        vm.etch(USDC, address(new MockUSDC()).code);
        vm.setEnv("PORTAGE_USDC", vm.toString(USDC));
        vm.setEnv("PORTAGE_GATEWAY_MINTER", vm.toString(MAINNET_MINTER));
        vm.setEnv("PORTAGE_GOVERNOR", vm.toString(multisig));
        vm.setEnv("PORTAGE_GUARDIAN", vm.toString(guardian));
        Deploy.Deployment memory dep = deploy.run();
        assertEq(address(dep.forwarder.gatewayMinter()), MAINNET_MINTER);
        assertEq(dep.governor, multisig);
        assertFalse(dep.wired, "a multisig governor wires itself");
    }
}
