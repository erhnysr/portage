// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @title AttestationDecoder
/// @notice Trustless calldata reader for Circle Gateway single-`Attestation` payloads. Extracts
///         only the fields Portage needs (recipient, destinationCaller, value, hookData, specHash)
///         at the exact byte offsets defined by the canonical Gateway contracts.
///
/// @dev Layout (from circlefin/evm-gateway-contracts, Attestations.sol + TransferSpec.sol):
///
///      Attestation envelope:
///        magic (4) | maxBlockHeight (32) | transferSpecLength (4) | encoded TransferSpec (…)
///        → the TransferSpec begins at attestation offset 40.
///
///      TransferSpec fields (relative to spec start = attestation offset 40):
///        destinationRecipient spec+176 (abs 216)   value spec+272 (abs 312)
///        destinationCaller    spec+240 (abs 280)   hookDataLength spec+336 (abs 376)   hookData spec+340 (abs 380)
///
///      specHash = keccak256(encoded TransferSpec) — the same cross-chain id the GatewayMinter
///      records for replay protection (Mints.sol).
///
///      v0.1 supports the single-`Attestation` form only (not batched `AttestationSet`). Callers
///      MUST check the magic via {isSingleAttestation}. Calldata slicing reverts on any
///      out-of-bounds access, so truncated payloads fail safely.
library AttestationDecoder {
    bytes4 internal constant ATTESTATION_MAGIC = 0xff6fb334; // keccak256("circle.gateway.Attestation")[:4]

    // Attestation-absolute offsets.
    uint256 internal constant SPEC_OFFSET = 40;
    uint256 internal constant SPEC_LEN_OFFSET = 36;
    uint256 internal constant DEPOSITOR_OFFSET = 184; // 40 + 144
    uint256 internal constant RECIPIENT_OFFSET = 216; // 40 + 176
    uint256 internal constant CALLER_OFFSET = 280; // 40 + 240
    uint256 internal constant VALUE_OFFSET = 312; // 40 + 272
    uint256 internal constant HOOK_LEN_OFFSET = 376; // 40 + 336
    uint256 internal constant HOOK_OFFSET = 380; // 40 + 340

    error UnsupportedAttestationFormat(bytes4 magic);

    function isSingleAttestation(bytes calldata payload) internal pure returns (bool) {
        return bytes4(payload[0:4]) == ATTESTATION_MAGIC;
    }

    function requireSingleAttestation(bytes calldata payload) internal pure {
        bytes4 magic = bytes4(payload[0:4]);
        if (magic != ATTESTATION_MAGIC) revert UnsupportedAttestationFormat(magic);
    }

    function specHash(bytes calldata payload) internal pure returns (bytes32) {
        uint256 specLen = uint32(bytes4(payload[SPEC_LEN_OFFSET:SPEC_LEN_OFFSET + 4]));
        return keccak256(payload[SPEC_OFFSET:SPEC_OFFSET + specLen]);
    }

    function sourceDepositor(bytes calldata payload) internal pure returns (address) {
        return address(uint160(uint256(bytes32(payload[DEPOSITOR_OFFSET:DEPOSITOR_OFFSET + 32]))));
    }

    function destinationRecipient(bytes calldata payload) internal pure returns (address) {
        return address(uint160(uint256(bytes32(payload[RECIPIENT_OFFSET:RECIPIENT_OFFSET + 32]))));
    }

    function destinationCaller(bytes calldata payload) internal pure returns (address) {
        return address(uint160(uint256(bytes32(payload[CALLER_OFFSET:CALLER_OFFSET + 32]))));
    }

    function value(bytes calldata payload) internal pure returns (uint256) {
        return uint256(bytes32(payload[VALUE_OFFSET:VALUE_OFFSET + 32]));
    }

    function hookData(bytes calldata payload) internal pure returns (bytes calldata) {
        uint256 hookLen = uint32(bytes4(payload[HOOK_LEN_OFFSET:HOOK_LEN_OFFSET + 4]));
        return payload[HOOK_OFFSET:HOOK_OFFSET + hookLen];
    }
}
