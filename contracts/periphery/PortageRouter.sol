// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AppRegistry} from "../core/AppRegistry.sol";
import {Ledger} from "../core/Ledger.sol";
import {PayoutMeta, PayoutMetaLib} from "../lib/PayoutMetaLib.sol";

/// @title PortageRouter
/// @notice The landing zone for Gateway mints on Arc. USDC is minted here (the burn intent's
///         `destinationRecipient`), then the router decodes the authentic `hookData` and either
///         forwards the funds into the Core `Ledger` (happy path) or holds them in quarantine
///         (unattributable deposit) — it never credits the wrong app.
///
/// @dev Only the wired `PortageMintForwarder` may call {credit}, and it does so atomically in the
///      same transaction as the mint (so the credited amount is provably the just-minted USDC).
///
///      "No funds at rest" holds for the happy path: a successful credit immediately pulls the
///      USDC into the Ledger, leaving the router's own attributable balance at zero. The ONLY
///      funds the router holds are explicitly quarantined amounts awaiting governor resolution.
contract PortageRouter is Ownable2Step {
    using SafeERC20 for IERC20;
    using PayoutMetaLib for bytes;

    IERC20 public immutable usdc;
    Ledger public immutable ledger;
    AppRegistry public immutable registry;

    /// @notice The PortageMintForwarder allowed to call {credit}. Set once by the governor.
    address public forwarder;

    enum QuarantineReason {
        MalformedHookData,
        UnregisteredApp
    }

    /// @notice specHash => quarantined USDC amount (0 if none / already resolved).
    mapping(bytes32 specHash => uint256 amount) public quarantined;

    /// @notice Total currently held in quarantine (the router's only at-rest balance).
    uint256 public quarantinedTotal;

    /// @notice Guards against double-handling a specHash at the periphery (defense-in-depth over
    ///         the Ledger's own credit idempotency and the GatewayMinter's replay protection).
    mapping(bytes32 specHash => bool handled) public processed;

    event ForwarderUpdated(address indexed oldForwarder, address indexed newForwarder);
    event Credited(
        bytes32 indexed appId, bytes32 indexed account, uint256 amount, bytes32 indexed specHash, uint8 action, bytes32 referenceId
    );
    event Quarantined(bytes32 indexed specHash, uint256 amount, QuarantineReason reason);
    event QuarantineResolved(bytes32 indexed specHash, bytes32 indexed appId, bytes32 indexed account, uint256 amount);
    event QuarantineWithdrawn(bytes32 indexed specHash, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotForwarder(address caller);
    error AlreadyProcessed(bytes32 specHash);
    error NothingQuarantined(bytes32 specHash);
    error AppNotRegistered(bytes32 appId);

    constructor(address governor_, address usdc_, address ledger_, address registry_) Ownable(governor_) {
        if (usdc_ == address(0) || ledger_ == address(0) || registry_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        ledger = Ledger(ledger_);
        registry = AppRegistry(registry_);
        // Pre-approve the Ledger to pull credited USDC out of this router.
        IERC20(usdc_).forceApprove(ledger_, type(uint256).max);
    }

    modifier onlyForwarder() {
        if (msg.sender != forwarder) revert NotForwarder(msg.sender);
        _;
    }

    // ---------------------------------------------------------------------
    // Governor wiring / recovery
    // ---------------------------------------------------------------------

    function setForwarder(address newForwarder) external onlyOwner {
        if (newForwarder == address(0)) revert ZeroAddress();
        emit ForwarderUpdated(forwarder, newForwarder);
        forwarder = newForwarder;
    }

    /// @notice Resolve a quarantined deposit by crediting it to the correct app sub-account
    ///         after manual review. Governor only.
    function resolveQuarantineToApp(bytes32 specHash, bytes32 appId, bytes32 account) external onlyOwner {
        uint256 amount = quarantined[specHash];
        if (amount == 0) revert NothingQuarantined(specHash);
        if (!registry.isRegistered(appId)) revert AppNotRegistered(appId);

        delete quarantined[specHash];
        quarantinedTotal -= amount;

        ledger.credit(appId, account, amount, specHash);
        emit QuarantineResolved(specHash, appId, account, amount);
    }

    /// @notice Withdraw a quarantined deposit (e.g. to refund it). Governor only.
    function withdrawQuarantine(bytes32 specHash, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = quarantined[specHash];
        if (amount == 0) revert NothingQuarantined(specHash);

        delete quarantined[specHash];
        quarantinedTotal -= amount;

        usdc.safeTransfer(to, amount);
        emit QuarantineWithdrawn(specHash, to, amount);
    }

    // ---------------------------------------------------------------------
    // Credit (called by the forwarder, in the same tx as the mint)
    // ---------------------------------------------------------------------

    /// @notice Attribute a just-minted deposit. Decodes the authentic hookData; on a valid,
    ///         registered app it forwards the USDC into the Ledger, otherwise it quarantines.
    ///         Never reverts on bad hookData (so the atomic mint still completes and funds are
    ///         captured in quarantine rather than mis-credited or stranded).
    /// @param hookData     The PayoutMeta bytes from the signed TransferSpec.
    /// @param mintedValue  The exact USDC amount just minted to this router (balance delta).
    /// @param specHash     The Gateway spec hash (idempotency key).
    function credit(bytes calldata hookData, uint256 mintedValue, bytes32 specHash) external onlyForwarder {
        if (processed[specHash]) revert AlreadyProcessed(specHash);
        processed[specHash] = true;

        (bool ok, PayoutMeta memory m) = hookData.tryDecode();

        if (!ok) {
            _quarantine(specHash, mintedValue, QuarantineReason.MalformedHookData);
            return;
        }
        if (!registry.isRegistered(m.appId)) {
            _quarantine(specHash, mintedValue, QuarantineReason.UnregisteredApp);
            return;
        }

        // Happy path: forward into the Core. Ledger.credit pulls `mintedValue` from this router,
        // returning the router's attributable balance to zero. (Credit is allowed even if the app
        // is paused — pause only halts outflows.)
        ledger.credit(m.appId, m.account, mintedValue, specHash);
        emit Credited(m.appId, m.account, mintedValue, specHash, m.action, m.referenceId);
    }

    function _quarantine(bytes32 specHash, uint256 amount, QuarantineReason reason) private {
        quarantined[specHash] = amount;
        quarantinedTotal += amount;
        emit Quarantined(specHash, amount, reason);
    }
}
