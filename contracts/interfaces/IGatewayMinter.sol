// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @notice Minimal interface for Circle's GatewayMinter (`0x0022222ABE238Cc2C7Bb1f21003F0a260052475B`).
///         `gatewayMint` verifies the Circle-signed attestation, then mints USDC to the
///         `destinationRecipient` encoded in the attestation's TransferSpec. It does NOT execute
///         hookData (verified against canonical source — see ARCHITECTURE.md §12).
interface IGatewayMinter {
    function gatewayMint(bytes calldata attestationPayload, bytes calldata signature) external;
}
