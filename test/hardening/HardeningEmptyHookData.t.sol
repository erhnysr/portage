// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {HardeningBase} from "./HardeningBase.sol";
import {PayoutMeta} from "../../contracts/lib/PayoutMetaLib.sol";

/// @notice Hardening A: the forward-compat `executeMint` must not accept an attestation with
///         empty hookData, so a third party cannot divert a v0.1 (meta-signed) deposit into
///         quarantine by front-running the depositor's `executeMintWithMeta`.
contract HardeningEmptyHookDataTest is HardeningBase {
    function test_executeMint_rejectsEmptyHookData_andMetaPathStillCredits() public {
        SpecParams memory p = _spec(5e6, keccak256("s1"), address(forwarder));
        bytes memory att = _buildAttestation(p);
        bytes memory sig = _sign(signerPk, att);
        bytes32 sh = _specHash(p);
        PayoutMeta memory meta = _meta();
        bytes memory metaSig = _signMeta(sh, meta);

        vm.prank(attacker);
        vm.expectRevert();
        forwarder.executeMint(att, sig);

        assertEq(router.quarantined(sh), 0, "nothing diverted");

        vm.prank(relayer);
        forwarder.executeMintWithMeta(att, sig, meta, metaSig);
        assertEq(ledger.balanceOf(APP, ARENA), 5e6, "depositor's meta path still credits the app");
    }
}
