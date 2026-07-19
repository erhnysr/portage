// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGatewayMinter} from "../interfaces/IGatewayMinter.sol";
import {AttestationDecoder} from "../lib/AttestationDecoder.sol";
import {PortageRouter} from "./PortageRouter.sol";

/// @title PortageMintForwarder
/// @notice Portage's on-chain composition primitive — "the hook Gateway does not provide."
///         In a single atomic transaction it (1) reads the authentic recipient/hookData/specHash
///         from the Circle-signed attestation, (2) calls `gatewayMint` (which mints USDC to the
///         router and reverts unless the attestation is Circle-signed and the caller matches the
///         intent's `destinationCaller`), and (3) credits the router by the exact minted amount.
///
/// @dev Authenticity is inherited from `gatewayMint`: because the mint reverts on any tampering,
///      the hookData/value we read from the same payload are guaranteed to be the Circle-signed
///      ones. The credited amount is measured as the router's USDC balance delta, so it is always
///      the real minted quantity regardless of what the payload claims.
///
///      The burn intent must set `destinationRecipient = router` and `destinationCaller = this`
///      forwarder, so only this contract can execute the mint (front-run / orphaned-mint proof).
contract PortageMintForwarder is ReentrancyGuard {
    using AttestationDecoder for bytes;

    IERC20 public immutable usdc;
    IGatewayMinter public immutable gatewayMinter;
    PortageRouter public immutable router;

    event MintExecuted(bytes32 indexed specHash, uint256 mintedValue);

    error ZeroAddress();
    error RecipientNotRouter(address recipient);
    error NothingMinted(bytes32 specHash);

    constructor(address usdc_, address gatewayMinter_, address router_) {
        if (usdc_ == address(0) || gatewayMinter_ == address(0) || router_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        gatewayMinter = IGatewayMinter(gatewayMinter_);
        router = PortageRouter(router_);
    }

    /// @notice Execute a Gateway mint and credit the router atomically.
    /// @param attestationPayload  A single Circle Gateway `Attestation` (see AttestationDecoder).
    /// @param signature           The Circle attestation-signer signature over the payload.
    function executeMint(bytes calldata attestationPayload, bytes calldata signature) external nonReentrant {
        attestationPayload.requireSingleAttestation();

        address recipient = attestationPayload.destinationRecipient();
        if (recipient != address(router)) revert RecipientNotRouter(recipient);

        bytes32 specHash = attestationPayload.specHash();
        bytes calldata hookData = attestationPayload.hookData();

        // Measure the real minted amount as the router's USDC balance delta across the mint.
        uint256 balBefore = usdc.balanceOf(address(router));
        gatewayMinter.gatewayMint(attestationPayload, signature);
        uint256 minted = usdc.balanceOf(address(router)) - balBefore;
        if (minted == 0) revert NothingMinted(specHash);

        // Attribute the deposit (forwards into Core, or quarantines — never reverts on bad hookData).
        router.credit(hookData, minted, specHash);

        emit MintExecuted(specHash, minted);
    }
}
