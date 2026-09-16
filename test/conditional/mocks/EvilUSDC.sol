// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Callback receiver invoked by {EvilUSDC} on receipt, used to drive reentrancy tests.
interface ITokenCallbackReceiver {
    function onTokensReceived() external;
}

/// @notice A hostile 6-decimal USDC stand-in for adversarial tests ONLY. It adds two
///         behaviours that real USDC does not have but that the escrow must survive:
///           - a transfer blocklist (real USDC has one): transfers to a blocked address revert,
///             modelling a recipient that cannot be paid — proves per-recipient pull isolation
///             does not wedge the deal (T10).
///           - an optional receive-callback: transfers to `reentrantHook` re-enter the hook.
///             Real USDC has NO callback (D1); this stresses the escrow's CEI + nonReentrant
///             defence-in-depth (T7 / I14 / I15) even against a misbehaving token.
///
/// @dev The standard suite uses `test/mocks/MockUSDC.sol`; this token is confined to the
///      threat tests that need these behaviours.
contract EvilUSDC is ERC20 {
    mapping(address => bool) public blocked;
    address public reentrantHook;

    constructor() ERC20("Evil USDC", "eUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address who, bool v) external {
        blocked[who] = v;
    }

    function setReentrantHook(address who) external {
        reentrantHook = who;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) revert("USDC: recipient blocked");
        super._update(from, to, value);
        if (to != address(0) && to == reentrantHook) {
            ITokenCallbackReceiver(to).onTokensReceived();
        }
    }
}
