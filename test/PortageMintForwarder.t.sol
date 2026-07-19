// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {GatewayTestHelper} from "./helpers/GatewayTestHelper.sol";
import {PortageMintForwarder} from "../contracts/periphery/PortageMintForwarder.sol";
import {PortageRouter} from "../contracts/periphery/PortageRouter.sol";
import {Ledger} from "../contracts/core/Ledger.sol";
import {AppRegistry} from "../contracts/core/AppRegistry.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockGatewayMinter} from "./mocks/MockGatewayMinter.sol";
import {PayoutMeta, PayoutMetaLib, PayoutAction} from "../contracts/lib/PayoutMetaLib.sol";

/// @notice End-to-end tests of the atomic mint + credit path:
///         forwarder → (mock) GatewayMinter mints to router → router credits/quarantines → Ledger.
contract PortageMintForwarderTest is GatewayTestHelper {
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
    address payer = makeAddr("payer");

    uint256 signerPk = 0xA11CE;
    address attestationSigner;

    uint32 constant SRC_DOMAIN = 6; // Base Sepolia
    uint32 constant DST_DOMAIN = 26; // Arc
    bytes32 constant APP = keccak256("coliseum");
    bytes32 constant ARENA = keccak256("arena-1");

    function setUp() public {
        attestationSigner = vm.addr(signerPk);

        usdc = new MockUSDC();
        registry = new AppRegistry(governor);
        ledger = new Ledger(governor, address(usdc), address(registry));
        router = new PortageRouter(governor, address(usdc), address(ledger), address(registry));
        minter = new MockGatewayMinter(address(usdc), attestationSigner);
        forwarder = new PortageMintForwarder(address(usdc), address(minter), address(router));

        vm.startPrank(governor);
        ledger.setCreditor(address(router));
        router.setForwarder(address(forwarder));
        registry.registerApp(APP, appOwner, controller);
        vm.stopPrank();
    }

    function _meta(bytes32 appId, bytes32 account) internal view returns (bytes memory) {
        return PayoutMetaLib.encode(
            PayoutMeta({
                schema: 1,
                appId: appId,
                account: account,
                action: PayoutAction.ENTRY_FEE,
                referenceId: keccak256("ref-1"),
                payer: bytes32(uint256(uint160(payer)))
            })
        );
    }

    function _spec(uint256 value, bytes32 salt, bytes memory hookData) internal view returns (SpecParams memory) {
        return SpecParams({
            sourceDomain: SRC_DOMAIN,
            destinationDomain: DST_DOMAIN,
            destinationRecipient: address(router),
            destinationCaller: address(forwarder), // only the forwarder may mint
            value: value,
            salt: salt,
            hookData: hookData
        });
    }

    // ----- happy path: full consolidation -----

    function test_executeMint_creditsApp() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"), _meta(APP, ARENA));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);

        vm.prank(relayer);
        forwarder.executeMint(att, sig);

        assertEq(ledger.balanceOf(APP, ARENA), 5e6);
        assertEq(usdc.balanceOf(address(ledger)), 5e6);
        assertEq(usdc.balanceOf(address(router)), 0, "no funds at rest");
        assertTrue(router.processed(_specHash(p)));
    }

    // ----- destinationCaller enforcement (anti-front-run) -----

    function test_executeMint_onlyForwarderCanMint_directCallReverts() public {
        // destinationCaller is the forwarder; a relayer calling the minter directly must fail.
        SpecParams memory p = _spec(5e6, keccak256("salt1"), _meta(APP, ARENA));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);

        vm.expectRevert(
            abi.encodeWithSelector(MockGatewayMinter.InvalidDestinationCaller.selector, address(forwarder), relayer)
        );
        vm.prank(relayer);
        minter.gatewayMint(att, sig);

        // Nothing minted, nothing credited.
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(ledger.balanceOf(APP, ARENA), 0);
    }

    // ----- authenticity: a non-Circle signature cannot mint -----

    function test_executeMint_badSignatureReverts() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"), _meta(APP, ARENA));
        bytes memory att = _buildAttestation(p);
        bytes memory badSig = _sign(0xBAD5161, att); // wrong signer key

        vm.expectRevert(
            abi.encodeWithSelector(MockGatewayMinter.InvalidAttestationSigner.selector, vm.addr(0xBAD5161))
        );
        vm.prank(relayer);
        forwarder.executeMint(att, badSig);
    }

    // ----- recipient must be the router -----

    function test_executeMint_recipientNotRouterReverts() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"), _meta(APP, ARENA));
        p.destinationRecipient = makeAddr("someoneElse");
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);

        vm.expectRevert(
            abi.encodeWithSelector(PortageMintForwarder.RecipientNotRouter.selector, p.destinationRecipient)
        );
        vm.prank(relayer);
        forwarder.executeMint(att, sig);
    }

    // ----- replay protection -----

    function test_executeMint_replayReverts() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"), _meta(APP, ARENA));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);

        vm.startPrank(relayer);
        forwarder.executeMint(att, sig);
        // Second submission: the minter's spec-hash replay guard fires.
        vm.expectRevert(abi.encodeWithSelector(MockGatewayMinter.AlreadyUsed.selector, _specHash(p)));
        forwarder.executeMint(att, sig);
        vm.stopPrank();

        assertEq(ledger.balanceOf(APP, ARENA), 5e6); // credited exactly once
    }

    // ----- malformed hookData: mint completes, funds quarantined atomically -----

    function test_executeMint_malformedHookData_quarantines() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"), hex"deadbeef");
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);

        vm.prank(relayer);
        forwarder.executeMint(att, sig);

        bytes32 sh = _specHash(p);
        assertEq(router.quarantined(sh), 5e6);
        assertEq(router.quarantinedTotal(), 5e6);
        assertEq(usdc.balanceOf(address(router)), 5e6, "held in quarantine, not lost");
        assertEq(ledger.custodyTotal(), 0, "never credited to any app");
    }

    // ----- unregistered app: quarantined, then resolvable -----

    function test_executeMint_unregisteredApp_quarantinesThenResolves() public {
        bytes32 ghost = keccak256("ghost-app");
        SpecParams memory p = _spec(8e6, keccak256("salt1"), _meta(ghost, ARENA));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);

        vm.prank(relayer);
        forwarder.executeMint(att, sig);

        bytes32 sh = _specHash(p);
        assertEq(router.quarantined(sh), 8e6);

        // Governor reattributes to the real app.
        vm.prank(governor);
        router.resolveQuarantineToApp(sh, APP, ARENA);

        assertEq(ledger.balanceOf(APP, ARENA), 8e6);
        assertEq(router.quarantinedTotal(), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // ----- conservation across a mixed batch -----

    function test_conservation_mixedDeposits() public {
        // Two good, one malformed.
        _mint(5e6, "s1", _meta(APP, ARENA));
        _mint(3e6, "s2", _meta(APP, keccak256("arena-2")));
        _mint(4e6, "s3", hex"1234"); // malformed -> quarantine

        uint256 totalMinted = 12e6;
        assertEq(ledger.custodyTotal() + router.quarantinedTotal(), totalMinted);
        assertEq(usdc.balanceOf(address(ledger)), ledger.custodyTotal());
        assertEq(usdc.balanceOf(address(router)), router.quarantinedTotal());
        assertEq(ledger.balanceOf(APP, ARENA), 5e6);
        assertEq(ledger.balanceOf(APP, keccak256("arena-2")), 3e6);
    }

    function _mint(uint256 value, bytes32 salt, bytes memory hookData) internal {
        SpecParams memory p = _spec(value, salt, hookData);
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        vm.prank(relayer);
        forwarder.executeMint(att, sig);
    }
}
