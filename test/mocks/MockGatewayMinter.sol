// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AttestationDecoder} from "../../contracts/lib/AttestationDecoder.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @notice Faithful stand-in for Circle's GatewayMinter, mirroring the checks in the canonical
///         Mints.sol that matter to Portage:
///           - verifies the attestation signer (authenticity)         [Mints.sol:257]
///           - enforces destinationCaller == msg.sender when set       [Mints.sol:296]
///           - replay-protects on the spec hash                        [Mints.sol:335]
///           - mints `value` USDC to `destinationRecipient`            [Mints.sol:349]
///           - ignores hookData entirely (no hook execution)           [Mints.sol:333-353]
contract MockGatewayMinter {
    using AttestationDecoder for bytes;

    MockUSDC public immutable usdc;
    address public immutable attestationSigner;

    mapping(bytes32 specHash => bool used) public usedSpecHash;

    event Minted(bytes32 indexed specHash, address indexed recipient, uint256 value);

    error InvalidAttestationSigner(address recovered);
    error InvalidDestinationCaller(address expected, address actual);
    error AlreadyUsed(bytes32 specHash);

    constructor(address usdc_, address attestationSigner_) {
        usdc = MockUSDC(usdc_);
        attestationSigner = attestationSigner_;
    }

    function gatewayMint(bytes calldata attestationPayload, bytes calldata signature) external {
        // (1) Authenticity: the payload must be signed by the configured attestation signer.
        address recovered =
            ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(keccak256(attestationPayload)), signature);
        if (recovered != attestationSigner) revert InvalidAttestationSigner(recovered);

        attestationPayload.requireSingleAttestation();

        // (2) destinationCaller: if set, only that address may execute the mint (anti-front-run).
        address caller = attestationPayload.destinationCaller();
        if (caller != address(0) && caller != msg.sender) revert InvalidDestinationCaller(caller, msg.sender);

        // (3) Replay protection on the spec hash.
        bytes32 sh = attestationPayload.specHash();
        if (usedSpecHash[sh]) revert AlreadyUsed(sh);
        usedSpecHash[sh] = true;

        // (4) Mint to the recipient. hookData is intentionally NOT read or executed.
        address recipient = attestationPayload.destinationRecipient();
        uint256 value = attestationPayload.value();
        usdc.mint(recipient, value);

        emit Minted(sh, recipient, value);
    }
}
