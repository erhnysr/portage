// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IConditionalEscrow} from "../../../contracts/conditions/IConditionalEscrow.sol";
import {ITokenCallbackReceiver} from "./EvilUSDC.sol";

/// @notice A recipient that attempts to re-enter `ConditionalEscrow.claim` while it is being
///         paid (via {EvilUSDC}'s receive callback). Used to prove the escrow's CEI ordering
///         (I14) and reentrancy guard (I15) block a second payout — the reentrant claim must
///         fail, so the attacker is paid at most once.
contract ReentrantRecipient is ITokenCallbackReceiver {
    IConditionalEscrow public immutable escrow;
    bytes32 public dealId;
    bool public reentered;

    constructor(IConditionalEscrow escrow_) {
        escrow = escrow_;
    }

    function arm(bytes32 dealId_) external {
        dealId = dealId_;
    }

    function onTokensReceived() external {
        // Re-enter exactly once. A correct implementation makes this inner claim revert (CEI +
        // guard); we swallow that revert so the OUTER claim still completes and pays exactly
        // once. If the inner claim were to SUCCEED (a bug), we force a revert to fail the test.
        if (!reentered) {
            reentered = true;
            try escrow.claim(dealId) {
                revert("reentrancy succeeded: double payout");
            } catch {
                // expected: the reentrant claim is rejected
            }
        }
    }

    /// @notice Kick off the first (outer) claim as this recipient.
    function claim() external {
        escrow.claim(dealId);
    }
}
