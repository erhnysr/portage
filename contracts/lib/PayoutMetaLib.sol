// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @notice Portage payout metadata carried inside the Gateway burn intent's `hookData`
///         (ARCHITECTURE.md §4). Because hookData is folded into the Circle-signed TransferSpec
///         hash, it is tamper-evident: a mint whose hookData was altered would fail attestation
///         verification inside `gatewayMint`.
struct PayoutMeta {
    uint8 schema; // version tag, =1 for v1
    bytes32 appId; // which app's ledger to credit
    bytes32 account; // sub-account within the app (e.g. an arena id)
    uint8 action; // see PayoutAction
    bytes32 referenceId; // app-side id for reconciliation
    bytes32 payer; // original depositor (audit trail)
}

/// @notice Action semantics for a consolidation credit (informational; recorded in events).
library PayoutAction {
    uint8 internal constant CREDIT = 0;
    uint8 internal constant ENTRY_FEE = 1;
    uint8 internal constant ESCROW_FUND = 2;
    uint8 internal constant TOPUP = 3;
}

library PayoutMetaLib {
    uint8 internal constant SCHEMA_V1 = 1;
    /// abi.encode of (uint8, bytes32, bytes32, uint8, bytes32, bytes32): six 32-byte words.
    uint256 internal constant ENCODED_LEN = 192;

    function encode(PayoutMeta memory m) internal pure returns (bytes memory) {
        return abi.encode(m.schema, m.appId, m.account, m.action, m.referenceId, m.payer);
    }

    /// @notice Decodes without reverting on malformed input. Returns `ok == false` for any
    ///         payload that is not a well-formed v1 PayoutMeta, so the caller can quarantine
    ///         rather than revert (and thus never mis-credit).
    function tryDecode(bytes memory data) internal pure returns (bool ok, PayoutMeta memory m) {
        if (data.length != ENCODED_LEN) return (false, m);

        (uint8 schema, bytes32 appId, bytes32 account, uint8 action, bytes32 referenceId, bytes32 payer) =
            abi.decode(data, (uint8, bytes32, bytes32, uint8, bytes32, bytes32));

        m = PayoutMeta({
            schema: schema,
            appId: appId,
            account: account,
            action: action,
            referenceId: referenceId,
            payer: payer
        });

        if (schema != SCHEMA_V1) return (false, m);
        return (true, m);
    }
}
