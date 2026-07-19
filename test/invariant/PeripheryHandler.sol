// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PortageMintForwarder} from "../../contracts/periphery/PortageMintForwarder.sol";
import {PortageRouter} from "../../contracts/periphery/PortageRouter.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {PayoutMeta, PayoutMetaLib} from "../../contracts/lib/PayoutMetaLib.sol";

/// @notice Drives the full periphery path (forwarder → mock minter → router → ledger) with a mix
///         of valid and malformed deposits, building/signing attestations inline at the canonical
///         byte offsets. Ghost accounting mirrors the split between credited and quarantined funds.
contract PeripheryHandler is CommonBase, StdUtils {
    PortageMintForwarder public immutable forwarder;
    PortageRouter public immutable router;
    Ledger public immutable ledger;
    uint256 private immutable signerPk;

    bytes32[] public apps;
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
        bytes32[] memory apps_,
        bytes32[] memory accounts_
    ) {
        forwarder = forwarder_;
        router = router_;
        ledger = ledger_;
        signerPk = signerPk_;
        apps = apps_;
        accounts = accounts_;
    }

    function consolidate(uint256 appSeed, uint256 acctSeed, uint256 amount, uint256 mode) external {
        bytes32 appId = apps[appSeed % apps.length];
        bytes32 account = accounts[acctSeed % accounts.length];
        amount = bound(amount, 1, 1_000_000e6);
        bool malformed = (mode % 3 == 0);

        bytes memory hookData = malformed
            ? bytes(hex"deadbeef")
            : PayoutMetaLib.encode(
                PayoutMeta({
                    schema: 1,
                    appId: appId,
                    account: account,
                    action: 1,
                    referenceId: keccak256(abi.encode("ref", _nonce)),
                    payer: bytes32(0)
                })
            );

        bytes memory att = _buildAttestation(amount, keccak256(abi.encode("salt", _nonce++)), hookData);
        bytes memory sig = _sign(att);

        forwarder.executeMint(att, sig);

        ghostMinted += amount;
        if (malformed) {
            ghostQuarantine += amount;
        } else {
            ghostBalance[appId][account] += amount;
            ghostAppTotal[appId] += amount;
            ghostCustody += amount;
        }
    }

    // --- inline attestation encoding at canonical offsets (see AttestationDecoder) ---

    function _buildAttestation(uint256 value, bytes32 salt, bytes memory hookData) private view returns (bytes memory) {
        bytes memory head = abi.encodePacked(
            bytes4(0xca85def7),
            uint32(1),
            uint32(6),
            uint32(26),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(uint256(uint160(address(router)))) // recipient
        );
        bytes memory tail = abi.encodePacked(
            bytes32(0),
            bytes32(uint256(uint160(address(forwarder)))), // destinationCaller
            value,
            salt,
            uint32(hookData.length),
            hookData
        );
        bytes memory spec = abi.encodePacked(head, tail);
        return abi.encodePacked(bytes4(0xff6fb334), uint256(type(uint256).max), uint32(spec.length), spec);
    }

    function _sign(bytes memory att) private view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(keccak256(att));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function appsLength() external view returns (uint256) {
        return apps.length;
    }
}
