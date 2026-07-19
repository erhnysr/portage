// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Builds Circle Gateway single-`Attestation` payloads at the exact byte offsets the
///         real contracts use, and signs them with a test attestation-signer key. Shared by the
///         router / forwarder tests.
abstract contract GatewayTestHelper is Test {
    bytes4 internal constant ATTESTATION_MAGIC = 0xff6fb334;
    bytes4 internal constant TRANSFER_SPEC_MAGIC = 0xca85def7;

    struct SpecParams {
        uint32 sourceDomain;
        uint32 destinationDomain;
        address destinationRecipient;
        address destinationCaller;
        uint256 value;
        bytes32 salt;
        bytes hookData;
    }

    /// @dev Encodes a TransferSpec with fields at their canonical offsets (see TransferSpec.sol).
    ///      Split into two concatenations to stay within the stack limit.
    function _encodeSpec(SpecParams memory p) internal pure returns (bytes memory) {
        bytes memory head = abi.encodePacked(
            TRANSFER_SPEC_MAGIC, // 0   (4)
            uint32(1), // 4   version (4)
            p.sourceDomain, // 8   (4)
            p.destinationDomain, // 12  (4)
            bytes32(0), // 16  sourceContract
            bytes32(0), // 48  destinationContract
            bytes32(0), // 80  sourceToken
            bytes32(0), // 112 destinationToken
            bytes32(0), // 144 sourceDepositor
            bytes32(uint256(uint160(p.destinationRecipient))) // 176 recipient
        );
        bytes memory tail = abi.encodePacked(
            bytes32(0), // 208 sourceSigner
            bytes32(uint256(uint160(p.destinationCaller))), // 240 destinationCaller
            p.value, // 272 value (32)
            p.salt, // 304 salt (32)
            uint32(p.hookData.length), // 336 hookDataLength (4)
            p.hookData // 340 hookData
        );
        return abi.encodePacked(head, tail);
    }

    /// @dev Wraps a spec in an Attestation envelope (see Attestations.sol).
    function _buildAttestation(SpecParams memory p) internal pure returns (bytes memory) {
        bytes memory spec = _encodeSpec(p);
        return abi.encodePacked(
            ATTESTATION_MAGIC, // 0  (4)
            uint256(type(uint256).max), // 4  maxBlockHeight (32) — never expires
            uint32(spec.length), // 36 transferSpecLength (4)
            spec // 40 encoded spec
        );
    }

    /// @dev Signs the attestation payload with `signerPk` the way the minter expects.
    function _sign(uint256 signerPk, bytes memory attestation) internal pure returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(keccak256(attestation));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev The spec hash = keccak256 of the encoded TransferSpec (matches the minter).
    function _specHash(SpecParams memory p) internal pure returns (bytes32) {
        return keccak256(_encodeSpec(p));
    }
}
