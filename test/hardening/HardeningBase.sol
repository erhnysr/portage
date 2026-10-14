// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {GatewayTestHelper} from "../helpers/GatewayTestHelper.sol";
import {PortageMintForwarder} from "../../contracts/periphery/PortageMintForwarder.sol";
import {PortageRouter} from "../../contracts/periphery/PortageRouter.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {AppRegistry} from "../../contracts/core/AppRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockGatewayMinter} from "../mocks/MockGatewayMinter.sol";
import {PayoutMeta, PayoutAction} from "../../contracts/lib/PayoutMetaLib.sol";

/// @notice Shared fixture for the mainnet-hardening tests.
abstract contract HardeningBase is GatewayTestHelper {
    PortageMintForwarder forwarder;
    PortageRouter router;
    Ledger ledger;
    AppRegistry registry;
    MockUSDC usdc;
    MockGatewayMinter minter;

    address governor = makeAddr("governor");
    address appOwner = makeAddr("appOwner");
    address controller = makeAddr("controller");
    address relayer = makeAddr("relayer");
    address attacker = makeAddr("attacker");

    uint256 signerPk = 0xA11CE;
    uint256 depositorPk = 0xD3903170;
    address depositor;

    bytes32 constant APP = keccak256("coliseum");
    bytes32 constant ARENA = keccak256("arena-1");

    function setUp() public virtual {
        depositor = vm.addr(depositorPk);
        usdc = new MockUSDC();
        registry = new AppRegistry(governor);
        ledger = new Ledger(governor, address(usdc), address(registry));
        router = new PortageRouter(governor, address(usdc), address(ledger), address(registry));
        minter = new MockGatewayMinter(address(usdc), vm.addr(signerPk));
        forwarder = new PortageMintForwarder(address(usdc), address(minter), address(router));

        vm.startPrank(governor);
        ledger.setCreditor(address(router));
        router.setForwarder(address(forwarder));
        registry.registerApp(APP, appOwner, controller);
        vm.stopPrank();
    }

    function _spec(uint256 value, bytes32 salt, address caller) internal view returns (SpecParams memory) {
        return SpecParams({
            sourceDomain: 6,
            destinationDomain: 26,
            sourceDepositor: depositor,
            destinationRecipient: address(router),
            destinationCaller: caller,
            value: value,
            salt: salt,
            hookData: ""
        });
    }

    function _meta() internal view returns (PayoutMeta memory) {
        return PayoutMeta({
            schema: 1,
            appId: APP,
            account: ARENA,
            action: PayoutAction.ENTRY_FEE,
            referenceId: keccak256("ref-1"),
            payer: bytes32(uint256(uint160(depositor)))
        });
    }

    function _signMeta(bytes32 sh, PayoutMeta memory meta) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(depositorPk, forwarder.hashMetaBinding(sh, meta));
        return abi.encodePacked(r, s, v);
    }
}
