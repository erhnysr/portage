// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AppRegistry} from "../../contracts/core/AppRegistry.sol";
import {Ledger} from "../../contracts/core/Ledger.sol";
import {PayoutEngine} from "../../contracts/core/PayoutEngine.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {ConditionRegistry} from "../../contracts/conditions/ConditionRegistry.sol";
import {ConditionalEscrow} from "../../contracts/conditions/ConditionalEscrow.sol";
import {IConditionalEscrow} from "../../contracts/conditions/IConditionalEscrow.sol";

/// @notice Shared fixture for the conditional-settlement tests. Deploys REAL Portage core
///         (AppRegistry, Ledger, PayoutEngine) — not mocks — plus the escrow layer, and wires
///         the escrow as an app's payout controller per SPEC O3. Test contracts inherit this.
///
/// @dev All tests here are failing-first: `ConditionalEscrow` / `ConditionRegistry` are stubs
///      that revert `NotImplemented()`, so every assertion below is red until they are built.
abstract contract EscrowTestBase is Test {
    AppRegistry internal registry;
    Ledger internal ledger;
    PayoutEngine internal engine;
    ConditionRegistry internal condReg;
    ConditionalEscrow internal escrow;
    MockUSDC internal usdc;

    // Actors.
    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal appOwner = makeAddr("appOwner");
    address internal payer = makeAddr("payer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal stranger = makeAddr("stranger");

    // The one app v1 registers (SPEC D9/O2). The escrow is its payoutController (O3).
    bytes32 internal constant ESCROW_APP = keccak256("portage-escrow-v1");
    // A second app whose controller is NOT the escrow — used by the I17/D9 negative test.
    bytes32 internal constant FOREIGN_APP = keccak256("foreign-app");

    function setUp() public virtual {
        usdc = new MockUSDC();
        _setUpCore(address(usdc));
    }

    /// @dev Deploys and wires core + escrow against an arbitrary USDC-like token (so a threat
    ///      test can swap in a hostile token). Kept in one place so the wiring matches
    ///      production exactly except for the creditor stand-in noted below.
    function _setUpCore(address token) internal {
        registry = new AppRegistry(governor);
        ledger = new Ledger(governor, token, address(registry));
        engine = new PayoutEngine(address(registry), address(ledger));
        condReg = new ConditionRegistry(governor);
        escrow = new ConditionalEscrow(
            address(registry), address(ledger), address(engine), address(condReg), governor
        );

        vm.startPrank(governor);
        // In production the sole `creditor` is PortageRouter (SPEC §2.1b — there is only one
        // creditor slot). In these tests the test contract stands in as creditor so it can seed
        // Ledger balances directly, simulating a completed Gateway deposit
        // (PortageRouter -> Ledger.credit). The `debitor` is the REAL PayoutEngine, exactly as
        // in production, so the escrow's claim/refund path (PayoutEngine.payout -> Ledger.debit)
        // is exercised for real once implemented.
        ledger.setCreditor(address(this));
        ledger.setDebitor(address(engine));
        // O3: a single governor action wires the escrow as the app's payout controller.
        registry.registerApp(ESCROW_APP, appOwner, address(escrow));
        // A registered app whose controller is a stranger, not the escrow (for I17/D9).
        registry.registerApp(FOREIGN_APP, appOwner, stranger);
        registry.setGuardian(guardian);
        vm.stopPrank();

        // Back the creditor (this contract) with USDC so credits are fully collateralised.
        MockUSDC(token).mint(address(this), 1_000_000_000e6);
        IERC20(token).approve(address(ledger), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev The payer-committed deal id (SPEC D10 / I19).
    function _dealId(address payer_, bytes32 salt, address condition, uint256 amount, uint256 hardDeadline)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(payer_, salt, condition, amount, hardDeadline));
    }

    /// @dev Simulate a Gateway deposit landing on `(ESCROW_APP, dealId)`: the stand-in creditor
    ///      credits the Ledger, mirroring PortageRouter -> Ledger.credit (SPEC §2.1 / §2.1b).
    function _fund(bytes32 account, uint256 amount) internal {
        // called from the test contract, which is the creditor
        ledger.credit(ESCROW_APP, account, amount, keccak256(abi.encode("gw", account, amount)));
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory arr) {
        arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _amt1(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _amt2(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }
}
