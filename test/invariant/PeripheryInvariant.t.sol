// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PortageMintForwarder} from "../../contracts/periphery/PortageMintForwarder.sol";
import {PortageRouter} from "../../contracts/periphery/PortageRouter.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {AppRegistry} from "../../contracts/core/AppRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockGatewayMinter} from "../mocks/MockGatewayMinter.sol";
import {PeripheryHandler} from "./PeripheryHandler.sol";

/// @notice Invariant suite for the full inbound path. Randomized valid + malformed deposits must
///         never lose or misattribute funds: everything minted is either credited to the correct
///         app or held in quarantine, and the router never holds unaccounted USDC.
contract PeripheryInvariantTest is Test {
    PortageMintForwarder forwarder;
    PortageRouter router;
    Ledger ledger;
    AppRegistry registry;
    MockUSDC usdc;
    MockGatewayMinter minter;
    PeripheryHandler handler;

    uint256 signerPk = 0xA11CE;
    uint256 depositorPk = 0xD3903170;
    bytes32[] apps;
    bytes32[] accounts;

    function setUp() public {
        usdc = new MockUSDC();
        registry = new AppRegistry(address(this));
        ledger = new Ledger(address(this), address(usdc), address(registry));
        router = new PortageRouter(address(this), address(usdc), address(ledger), address(registry));
        minter = new MockGatewayMinter(address(usdc), vm.addr(signerPk));
        forwarder = new PortageMintForwarder(address(usdc), address(minter), address(router));

        ledger.setCreditor(address(router));
        router.setForwarder(address(forwarder));

        apps.push(keccak256("coliseum"));
        apps.push(keccak256("basedrop"));
        accounts.push(keccak256("acct-a"));
        accounts.push(keccak256("acct-b"));
        for (uint256 i = 0; i < apps.length; i++) {
            registry.registerApp(apps[i], address(this), address(this));
        }

        handler = new PeripheryHandler(forwarder, router, ledger, signerPk, depositorPk, apps, accounts);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = handler.consolidate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Nothing is created or destroyed: every minted unit is either credited or quarantined.
    function invariant_conservation() public view {
        assertEq(ledger.custodyTotal() + router.quarantinedTotal(), handler.ghostMinted());
        assertEq(ledger.custodyTotal(), handler.ghostCustody());
        assertEq(router.quarantinedTotal(), handler.ghostQuarantine());
    }

    /// The Ledger is solvent, and the router holds exactly (and only) the quarantined funds.
    function invariant_custodyAndRouterBalances() public view {
        assertGe(usdc.balanceOf(address(ledger)), ledger.custodyTotal());
        assertEq(usdc.balanceOf(address(ledger)), ledger.custodyTotal());
        assertEq(usdc.balanceOf(address(router)), router.quarantinedTotal());
    }

    /// Per-account isolation: credited balances match their independently tracked ghost values.
    function invariant_perAccountMatchesGhost() public view {
        for (uint256 i = 0; i < apps.length; i++) {
            for (uint256 j = 0; j < accounts.length; j++) {
                assertEq(ledger.balanceOf(apps[i], accounts[j]), handler.ghostBalance(apps[i], accounts[j]));
            }
        }
    }
}
