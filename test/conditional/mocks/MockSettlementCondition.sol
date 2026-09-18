// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ISettlementCondition} from "../../../contracts/conditions/ISettlementCondition.sol";

/// @notice Configurable settlement condition for tests. A single mock covers the honest path
///         and the adversarial condition behaviours in the SPEC threat model:
///           - normal settled allocation                                  (I2 happy path)
///           - recipient outside the participant set                      (T1 / I11)
///           - amounts summing above the deal                             (T2 / I2)
///           - amounts summing below the deal                             (T3 / I2)
///           - reverting / bricked condition                              (T6 / I8)
///           - outcome mutated after the escrow's first read              (T8 / I16 / D5)
///
/// @dev `resolve` is `view` per SPEC §3, so it cannot mutate; the non-view setters let a test
///      reconfigure the outcome BETWEEN reads to prove the escrow snapshots (D5) and never
///      re-reads (I16).
contract MockSettlementCondition is ISettlementCondition {
    bool private _settled;
    bool private _revertOnResolve;
    address[] private _recipients;
    uint256[] private _amounts;

    function setOutcome(bool settled_, address[] memory recipients_, uint256[] memory amounts_) external {
        _settled = settled_;
        _recipients = recipients_;
        _amounts = amounts_;
    }

    function setSettled(bool settled_) external {
        _settled = settled_;
    }

    function setRevertOnResolve(bool v) external {
        _revertOnResolve = v;
    }

    function resolve(bytes32)
        external
        view
        returns (bool settled, address[] memory recipients, uint256[] memory amounts)
    {
        if (_revertOnResolve) revert("condition bricked");
        return (_settled, _recipients, _amounts);
    }
}
