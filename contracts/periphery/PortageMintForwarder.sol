// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IGatewayMinter} from "../interfaces/IGatewayMinter.sol";
import {AttestationDecoder} from "../lib/AttestationDecoder.sol";
import {PayoutMeta, PayoutMetaLib} from "../lib/PayoutMetaLib.sol";
import {PortageRouter} from "./PortageRouter.sol";

/// @title PortageMintForwarder
/// @notice Portage's on-chain composition primitive — "the hook Gateway does not provide."
///         In a single atomic transaction it (1) validates the transfer, (2) calls `gatewayMint`
///         (which mints USDC to the router and reverts unless the attestation is Circle-signed and
///         the caller matches the intent's `destinationCaller`), and (3) credits the router by the
///         exact minted amount.
///
/// @dev PayoutMeta delivery — two paths:
///
///      • `executeMintWithMeta` (PRIMARY, v0.1): PayoutMeta travels as a separate argument, bound
///        to the transfer's `specHash` by an EIP-712 signature from the `sourceDepositor`. This is
///        used because the Circle Gateway testnet transfer API returns 500 on non-empty `hookData`
///        (see ARCHITECTURE.md §13). The burn intent is submitted with EMPTY hookData; tamper-
///        evidence and app-isolation are preserved by verifying the depositor's meta signature.
///
///      • `executeMint` (forward-compat): reads PayoutMeta from the attestation's own hookData.
///        Usable once/if Gateway supports non-empty hookData end-to-end.
///
///      Authenticity of the transfer itself is inherited from `gatewayMint` (reverts on any
///      tampering). The credited amount is measured as the router's USDC balance delta, so it is
///      always the real minted quantity. The burn intent must set `destinationRecipient = router`
///      and `destinationCaller = this` forwarder (front-run / orphaned-mint proof).
contract PortageMintForwarder is ReentrancyGuard, EIP712 {
    using AttestationDecoder for bytes;

    /// EIP-712 type binding a PayoutMeta to a specific transfer (its specHash).
    bytes32 private constant META_BINDING_TYPEHASH = keccak256(
        "PayoutMetaBinding(bytes32 specHash,uint8 schema,bytes32 appId,bytes32 account,uint8 action,bytes32 referenceId,bytes32 payer)"
    );

    IERC20 public immutable usdc;
    IGatewayMinter public immutable gatewayMinter;
    PortageRouter public immutable router;

    event MintExecuted(bytes32 indexed specHash, uint256 mintedValue);

    error ZeroAddress();
    error RecipientNotRouter(address recipient);
    error NothingMinted(bytes32 specHash);
    error InvalidMetaSigner(address recovered, address expectedDepositor);

    constructor(address usdc_, address gatewayMinter_, address router_) EIP712("Portage", "1") {
        if (usdc_ == address(0) || gatewayMinter_ == address(0) || router_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        gatewayMinter = IGatewayMinter(gatewayMinter_);
        router = PortageRouter(router_);
    }

    /// @notice PRIMARY (v0.1): execute a Gateway mint and credit the router atomically, with the
    ///         PayoutMeta supplied separately and authorized by the depositor's EIP-712 signature.
    /// @param attestationPayload  A single Circle Gateway `Attestation` (empty hookData in v0.1).
    /// @param signature           The Circle attestation-signer signature over the payload.
    /// @param meta                The PayoutMeta describing how to credit this deposit.
    /// @param metaSig             The `sourceDepositor`'s EIP-712 signature over (specHash, meta).
    function executeMintWithMeta(
        bytes calldata attestationPayload,
        bytes calldata signature,
        PayoutMeta calldata meta,
        bytes calldata metaSig
    ) external nonReentrant {
        attestationPayload.requireSingleAttestation();

        address recipient = attestationPayload.destinationRecipient();
        if (recipient != address(router)) revert RecipientNotRouter(recipient);

        bytes32 specHash = attestationPayload.specHash();

        // The meta must be authorized by the same user who deposited on the source chain.
        address depositor = attestationPayload.sourceDepositor();
        address signer = ECDSA.recover(hashMetaBinding(specHash, meta), metaSig);
        if (signer != depositor) revert InvalidMetaSigner(signer, depositor);

        uint256 minted = _mintToRouter(attestationPayload, signature, specHash);
        router.credit(PayoutMetaLib.encode(meta), minted, specHash);

        emit MintExecuted(specHash, minted);
    }

    /// @notice FORWARD-COMPAT: execute a mint and credit using PayoutMeta carried in the
    ///         attestation's own hookData. Only useful when Gateway carries non-empty hookData.
    function executeMint(bytes calldata attestationPayload, bytes calldata signature) external nonReentrant {
        attestationPayload.requireSingleAttestation();

        address recipient = attestationPayload.destinationRecipient();
        if (recipient != address(router)) revert RecipientNotRouter(recipient);

        bytes32 specHash = attestationPayload.specHash();
        bytes calldata hookData = attestationPayload.hookData();

        uint256 minted = _mintToRouter(attestationPayload, signature, specHash);
        router.credit(hookData, minted, specHash);

        emit MintExecuted(specHash, minted);
    }

    /// @notice The EIP-712 digest a depositor signs to authorize `meta` for transfer `specHash`.
    ///         Exposed so off-chain signers and tests can produce a matching signature.
    function hashMetaBinding(bytes32 specHash, PayoutMeta calldata meta) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    META_BINDING_TYPEHASH,
                    specHash,
                    meta.schema,
                    meta.appId,
                    meta.account,
                    meta.action,
                    meta.referenceId,
                    meta.payer
                )
            )
        );
    }

    /// @dev Mints via Gateway to the router and returns the measured balance delta.
    function _mintToRouter(bytes calldata attestationPayload, bytes calldata signature, bytes32 specHash)
        private
        returns (uint256 minted)
    {
        uint256 balBefore = usdc.balanceOf(address(router));
        gatewayMinter.gatewayMint(attestationPayload, signature);
        minted = usdc.balanceOf(address(router)) - balBefore;
        if (minted == 0) revert NothingMinted(specHash);
    }
}
