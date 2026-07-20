// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PortageMintForwarder} from "../../contracts/periphery/PortageMintForwarder.sol";
import {PortageRouter} from "../../contracts/periphery/PortageRouter.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {PayoutMeta} from "../../contracts/lib/PayoutMetaLib.sol";

/// @notice Drives the full v0.1 periphery path (forwarder.executeMintWithMeta → mock minter →
///         router → ledger) with a mix of registered (credited) and unregistered (quarantined)
///         apps, building/signing attestations + meta bindings inline. Ghost accounting mirrors
///         the split between credited and quarantined funds.
contract PeripheryHandler is CommonBase, StdUtils {
    PortageMintForwarder public immutable forwarder;
    PortageRouter public immutable router;
    Ledger public immutable ledger;
    uint256 private immutable signerPk;
    uint256 private immutable depositorPk;
    address public immutable depositor;

    bytes32[] public apps; // registered
    bytes32 public constant GHOST_APP = keccak256("ghost-unregistered");
    bytes32[] public accounts;

    uint256 public ghostMinted;
    uint256 public ghostCustody;
    uint256 public ghostQuarantine;
    mapping(bytes32 => uint256) public ghostAppTotal;
    mapping(bytes32 => mapping(bytes32 => uint256)) public ghostBalance;

    uint256 private _nonce;

    constructor(
        PortageMintForwarder forwarder_,
        PortageRouter router_,
        Ledger ledger_,
        uint256 signerPk_,
        uint256 depositorPk_,
        bytes32[] memory apps_,
        bytes32[] memory accounts_
    ) {
        forwarder = forwarder_;
        router = router_;
        ledger = ledger_;
        signerPk = signerPk_;
        depositorPk = depositorPk_;
        depositor = vm.addr(depositorPk_);
        apps = apps_;
        accounts = accounts_;
    }

    function consolidate(uint256 appSeed, uint256 acctSeed, uint256 amount, uint256 mode) external {
        bytes32 account = accounts[acctSeed % accounts.length];
        amount = bound(amount, 1, 1_000_000e6);
        bool quarantine = (mode % 3 == 0);
        bytes32 appId = quarantine ? GHOST_APP : apps[appSeed % apps.length];

        PayoutMeta memory meta = PayoutMeta({
            schema: 1,
            appId: appId,
            account: account,
            action: 1,
            referenceId: keccak256(abi.encode("ref", _nonce)),
            payer: bytes32(uint256(uint160(depositor)))
        });

        bytes memory att = _buildAttestation(amount, keccak256(abi.encode("salt", _nonce++)));
        bytes memory sig = _sign(signerPk, MessageHashUtils.toEthSignedMessageHash(keccak256(att)));
        bytes32 specHash = _specHash(att);
        bytes memory metaSig = _sign(depositorPk, forwarder.hashMetaBinding(specHash, meta));

        forwarder.executeMintWithMeta(att, sig, meta, metaSig);

        ghostMinted += amount;
        if (quarantine) {
            ghostQuarantine += amount;
        } else {
            ghostBalance[appId][account] += amount;
            ghostAppTotal[appId] += amount;
            ghostCustody += amount;
        }
    }

    // --- inline attestation encoding at canonical offsets (see AttestationDecoder) ---

    function _buildAttestation(uint256 value, bytes32 salt) private view returns (bytes memory) {
        bytes memory head = abi.encodePacked(
            bytes4(0xca85def7),
            uint32(1),
            uint32(6),
            uint32(26),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(uint256(uint160(depositor))) // sourceDepositor
        );
        bytes memory tail = abi.encodePacked(
            bytes32(uint256(uint160(address(router)))), // recipient
            bytes32(0),
            bytes32(uint256(uint160(address(forwarder)))), // destinationCaller
            value,
            salt,
            uint32(0), // empty hookData
            bytes("")
        );
        bytes memory spec = abi.encodePacked(head, tail);
        return abi.encodePacked(bytes4(0xff6fb334), uint256(type(uint256).max), uint32(spec.length), spec);
    }

    function _specHash(bytes memory att) private pure returns (bytes32) {
        // spec starts at attestation offset 40; length prefix at offset 36.
        uint32 specLen = uint32(bytes4(_slice4(att, 36)));
        bytes memory spec = new bytes(specLen);
        for (uint256 i = 0; i < specLen; i++) {
            spec[i] = att[40 + i];
        }
        return keccak256(spec);
    }

    function _slice4(bytes memory data, uint256 offset) private pure returns (bytes4 out) {
        assembly {
            out := mload(add(add(data, 0x20), offset))
        }
    }

    function _sign(uint256 pk, bytes32 digest) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function appsLength() external view returns (uint256) {
        return apps.length;
    }
}
