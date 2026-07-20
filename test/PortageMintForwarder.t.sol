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

/// @notice End-to-end tests of the atomic mint + credit path with the v0.1 decoupled PayoutMeta:
///         forwarder.executeMintWithMeta → (mock) GatewayMinter mints to router → router
///         credits/quarantines → Ledger. PayoutMeta is authorized by the depositor's EIP-712 sig.
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

    uint256 signerPk = 0xA11CE; // Circle attestation signer
    uint256 depositorPk = 0xD3903170; // the user who deposits + signs the meta binding
    address attestationSigner;
    address depositor;

    uint32 constant SRC_DOMAIN = 6; // Base Sepolia
    uint32 constant DST_DOMAIN = 26; // Arc
    bytes32 constant APP = keccak256("coliseum");
    bytes32 constant ARENA = keccak256("arena-1");

    function setUp() public {
        attestationSigner = vm.addr(signerPk);
        depositor = vm.addr(depositorPk);

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

    // ---- builders ----

    function _meta(bytes32 appId, bytes32 account) internal view returns (PayoutMeta memory) {
        return PayoutMeta({
            schema: 1,
            appId: appId,
            account: account,
            action: PayoutAction.ENTRY_FEE,
            referenceId: keccak256("ref-1"),
            payer: bytes32(uint256(uint160(depositor)))
        });
    }

    /// Empty-hookData spec (v0.1 flow): meta is delivered separately, not in hookData.
    function _spec(uint256 value, bytes32 salt) internal view returns (SpecParams memory) {
        return SpecParams({
            sourceDomain: SRC_DOMAIN,
            destinationDomain: DST_DOMAIN,
            sourceDepositor: depositor,
            destinationRecipient: address(router),
            destinationCaller: address(forwarder),
            value: value,
            salt: salt,
            hookData: "" // empty — Gateway testnet rejects non-empty hookData
        });
    }

    function _signMeta(uint256 pk, bytes32 specHash, PayoutMeta memory meta) internal view returns (bytes memory) {
        bytes32 digest = forwarder.hashMetaBinding(specHash, meta);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ---- happy path ----

    function test_executeMintWithMeta_creditsApp() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        bytes32 sh = _specHash(p);
        PayoutMeta memory meta = _meta(APP, ARENA);
        bytes memory metaSig = _signMeta(depositorPk, sh, meta);

        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, sig, meta, metaSig);

        assertEq(ledger.balanceOf(APP, ARENA), 5e6);
        assertEq(usdc.balanceOf(address(ledger)), 5e6);
        assertEq(usdc.balanceOf(address(router)), 0, "no funds at rest");
        assertTrue(router.processed(sh));
    }

    // ---- meta-binding security (the core of B1) ----

    function test_executeMintWithMeta_forgedMetaSig_reverts() public {
        // A relayer fabricates a meta signature with a key that is NOT the depositor's.
        SpecParams memory p = _spec(5e6, keccak256("salt1"));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        bytes32 sh = _specHash(p);
        PayoutMeta memory meta = _meta(APP, ARENA);
        bytes memory forged = _signMeta(0xBAD5161, sh, meta); // attacker key

        vm.expectRevert(
            abi.encodeWithSelector(PortageMintForwarder.InvalidMetaSigner.selector, vm.addr(0xBAD5161), depositor)
        );
        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, sig, meta, forged);

        // Nothing minted or credited.
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(ledger.custodyTotal(), 0);
    }

    function test_executeMintWithMeta_metaSignedForDifferentSpecHash_reverts() public {
        // Depositor signs the meta but bound to a DIFFERENT transfer's specHash. Must not verify
        // against this attestation (prevents replaying a meta authorization across transfers).
        SpecParams memory p = _spec(5e6, keccak256("salt1"));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        PayoutMeta memory meta = _meta(APP, ARENA);
        bytes memory wrongSig = _signMeta(depositorPk, keccak256("some-other-spec"), meta);

        vm.expectRevert(); // InvalidMetaSigner: recovered signer != depositor
        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, sig, meta, wrongSig);
    }

    function test_executeMintWithMeta_tamperedMetaAfterSigning_reverts() public {
        // Depositor authorizes meta for APP; relayer swaps in a meta for a different app.
        SpecParams memory p = _spec(5e6, keccak256("salt1"));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        bytes32 sh = _specHash(p);

        PayoutMeta memory authorized = _meta(APP, ARENA);
        bytes memory metaSig = _signMeta(depositorPk, sh, authorized);

        PayoutMeta memory tampered = _meta(keccak256("attacker-app"), ARENA);

        vm.expectRevert(); // digest over `tampered` != what depositor signed
        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, sig, tampered, metaSig);
    }

    // ---- destinationCaller enforcement (anti-front-run) ----

    function test_onlyForwarderCanMint_directCallReverts() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);

        vm.expectRevert(
            abi.encodeWithSelector(MockGatewayMinter.InvalidDestinationCaller.selector, address(forwarder), relayer)
        );
        vm.prank(relayer);
        minter.gatewayMint(att, sig);
        assertEq(ledger.balanceOf(APP, ARENA), 0);
    }

    // ---- authenticity: a non-Circle signature cannot mint ----

    function test_badAttestationSignatureReverts() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"));
        bytes memory att = _buildAttestation(p);
        bytes memory badSig = _sign(0xBAD5161, att);
        bytes32 sh = _specHash(p);
        PayoutMeta memory meta = _meta(APP, ARENA);
        bytes memory metaSig = _signMeta(depositorPk, sh, meta);

        vm.expectRevert(
            abi.encodeWithSelector(MockGatewayMinter.InvalidAttestationSigner.selector, vm.addr(0xBAD5161))
        );
        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, badSig, meta, metaSig);
    }

    // ---- recipient must be the router ----

    function test_recipientNotRouterReverts() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"));
        p.destinationRecipient = makeAddr("someoneElse");
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        bytes32 sh = _specHash(p);
        PayoutMeta memory meta = _meta(APP, ARENA);
        bytes memory metaSig = _signMeta(depositorPk, sh, meta);

        vm.expectRevert(
            abi.encodeWithSelector(PortageMintForwarder.RecipientNotRouter.selector, p.destinationRecipient)
        );
        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, sig, meta, metaSig);
    }

    // ---- replay protection ----

    function test_replayReverts() public {
        SpecParams memory p = _spec(5e6, keccak256("salt1"));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        bytes32 sh = _specHash(p);
        PayoutMeta memory meta = _meta(APP, ARENA);
        bytes memory metaSig = _signMeta(depositorPk, sh, meta);

        vm.startPrank(relayer);
        forwarder.executeMintWithMeta(att, sig, meta, metaSig);
        vm.expectRevert(abi.encodeWithSelector(MockGatewayMinter.AlreadyUsed.selector, sh));
        forwarder.executeMintWithMeta(att, sig, meta, metaSig);
        vm.stopPrank();

        assertEq(ledger.balanceOf(APP, ARENA), 5e6); // credited exactly once
    }

    // ---- unregistered app: quarantined, then resolvable ----

    function test_unregisteredApp_quarantinesThenResolves() public {
        bytes32 ghost = keccak256("ghost-app");
        SpecParams memory p = _spec(8e6, keccak256("salt1"));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        bytes32 sh = _specHash(p);
        PayoutMeta memory meta = _meta(ghost, ARENA);
        bytes memory metaSig = _signMeta(depositorPk, sh, meta);

        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, sig, meta, metaSig);

        assertEq(router.quarantined(sh), 8e6);

        vm.prank(governor);
        router.resolveQuarantineToApp(sh, APP, ARENA);

        assertEq(ledger.balanceOf(APP, ARENA), 8e6);
        assertEq(router.quarantinedTotal(), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    // ---- conservation across a mixed batch ----

    function test_conservation_mixedDeposits() public {
        _mintMeta(5e6, "s1", _meta(APP, ARENA)); // credited
        _mintMeta(3e6, "s2", _meta(APP, keccak256("arena-2"))); // credited
        _mintMeta(4e6, "s3", _meta(keccak256("ghost"), ARENA)); // unregistered -> quarantine

        assertEq(ledger.custodyTotal() + router.quarantinedTotal(), 12e6);
        assertEq(usdc.balanceOf(address(ledger)), ledger.custodyTotal());
        assertEq(usdc.balanceOf(address(router)), router.quarantinedTotal());
        assertEq(ledger.balanceOf(APP, ARENA), 5e6);
        assertEq(ledger.balanceOf(APP, keccak256("arena-2")), 3e6);
    }

    // ---- forward-compat path still works when hookData carries the meta ----

    function test_executeMint_hookDataPath_stillWorks() public {
        PayoutMeta memory meta = _meta(APP, ARENA);
        SpecParams memory p = _spec(6e6, keccak256("salt-hd"));
        p.hookData = PayoutMetaLib.encode(meta); // non-empty hookData (as if Gateway supported it)
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);

        vm.prank(relayer);
        forwarder.executeMint(att, sig);

        assertEq(ledger.balanceOf(APP, ARENA), 6e6);
    }

    function _mintMeta(uint256 value, bytes32 salt, PayoutMeta memory meta) internal {
        SpecParams memory p = _spec(value, salt);
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        bytes memory metaSig = _signMeta(depositorPk, _specHash(p), meta);
        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, sig, meta, metaSig);
    }
}
