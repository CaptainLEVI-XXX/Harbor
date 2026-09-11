// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {BookContext as Context} from "src/libraries/BookContext.sol";

import {SwapVM} from "@1inch/swap-vm/src/SwapVM.sol";
import {AssetUnits} from "src/libraries/AssetUnits.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {PricingState} from "src/libraries/PricingState.sol";
import {PricingCurve} from "src/types/PricingTypes.sol";
import {PricingMath} from "src/libraries/PricingMath.sol";
import {RedemptionAccounting} from "src/libraries/RedemptionAccounting.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {RouteConfig, Operation} from "src/types/HarborTypes.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";

/// @title BookState
/// @notice Shared immutable mandate, persistent ledgers and transaction-local locks.
/// @dev Every Book module inherits this one state owner. Domain libraries use fixed
/// compiler links and explicit storage references; no mutable dispatch.
/// Context lasts until explicit release. New deployments require fresh bindings.
abstract contract BookState is IHarborBook {
  /*//////////////////////////////////////////////////////////////
                                TYPES
  //////////////////////////////////////////////////////////////*/

  /// @notice Deployment-only mandate. Addresses and risk ceilings cannot be replaced.
  struct Config {
    /// @notice Predicted pooled maker and sole treasury address.
    address vault;
    /// @notice Predicted trader settlement entrypoint.
    address executor;
    /// @notice Approved settlement ERC-20; accounting uses its raw units.
    address asset;
    /// @notice Official Aqua balance-management deployment.
    address aqua;
    /// @notice Approved pinned AquaSwapVMRouter supporting Extruction and FeeProtocol.
    address router;
    /// @notice Initial scoped parameter publisher; replacement is governance-delayed.
    address updater;
    /// @notice Authority for bounded configuration operations.
    address governor;
    /// @notice Emergency stop and keeper-revocation authority.
    address guardian;
    /// @notice Only caller allowed to initiate issuer requests.
    address keeper;
    /// @notice Fixed beneficiary of settlement-asset-denominated trading fees.
    address feeRecipient;
    /// @notice Trading fee in basis points, at most 100.
    uint256 feeBps;
    /// @notice Unreserved cash floor in settlement-asset raw units.
    uint256 cashBuffer;
    /// @notice Maximum pricing observation-to-expiry interval in seconds.
    uint256 maxParameterAge;
    /// @notice Maximum public valuation age in seconds.
    uint256 maxMarkAge;
    /// @notice Aggregate acquisition-basis ceiling in settlement-asset raw units, independent of LP deposits.
    uint256 maxBasisExposure;
    /// @notice Delay for updater rotation and trading resumption, in seconds.
    uint256 governanceDelay;
    /// @notice Independent nominal FACE cap and inventory penalty parameters.
    PricingCurve curve;
  }

  /*//////////////////////////////////////////////////////////////
                         IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @dev Approved cash asset; all cash accounting uses settlement-asset raw units.
  address public immutable ASSET;
  /// @dev One whole settlement token in raw units; decimals fixed by admission.
  uint256 internal immutable ASSET_UNIT;
  /// @dev Fixed native units: route 0 in bits 0..63, route 1 in 64..127.
  /// Admission bounds each unit by 1e18 < 2^64; receipt lots never use this word.
  uint256 internal immutable BASE_UNITS;
  /// @dev Official shared strategy-balance ledger.
  address public immutable AQUA;
  /// @dev Only router allowed to authorize fills and deliver settlement hooks.
  address public immutable ROUTER;
  /// @dev Mandate administration authority.
  address public immutable GOVERNOR;
  /// @dev Emergency stop and irreversible keeper-revocation authority.
  address public immutable GUARDIAN;
  /// @dev Issuer-request initiator; never the recipient of treasury assets.
  address public immutable KEEPER;
  /// @dev Fixed ASSET fee beneficiary.
  address public immutable FEE_RECIPIENT;
  /// @dev Trading fee in basis points.
  uint256 public immutable FEE_BPS;
  /// @dev Cash floor excluded from new purchases, in settlement-asset raw units.
  uint256 public immutable CASH_BUFFER;
  /// @dev Maximum quote observation-to-expiry interval, seconds.
  uint256 public immutable MAX_PARAMETER_AGE;
  /// @dev Maximum age of public marks, seconds.
  uint256 public immutable MAX_MARK_AGE;
  /// @dev Aggregate warehouse plus pending acquisition basis ceiling, settlement-asset raw units.
  uint256 public immutable MAX_EXPOSURE;
  /// @dev Minimum delay for updater rotation or trading resumption, seconds.
  uint256 public immutable GOVERNANCE_DELAY;
  /// @dev Sole custody and LP-share accounting boundary.
  HarborVault public immutable VAULT;
  /// @dev Only caller permitted to open and finish a trade.
  HarborExecutor public immutable EXECUTOR;
  /// @notice Number of original inventory routes; receipt history is never iterated.
  uint256 public immutable INVENTORY_ROUTES;
  uint256 public immutable FACE_CAP;
  uint256 public immutable TARGET_UTILIZATION;
  uint256 public immutable CAPACITY_PENALTY;

  /*//////////////////////////////////////////////////////////////
                         PERSISTENT STATE
  //////////////////////////////////////////////////////////////*/

  /// @dev Publisher of reusable discounts; no treasury or valuation authority.
  address public parameterUpdater;
  /// @dev Persistent quote invalidation version; never reset by transaction cleanup.
  uint256 public configVersion;
  /// @dev Trading and fresh-mark gate; funded withdrawals and recovery remain available.
  bool public stopped;
  /// @dev Scheduled replacement updater; zero when no rotation is pending.
  address public pendingUpdater;
  /// @dev Earliest updater-rotation timestamp; zero disables application.
  uint256 public updaterReadyAt;
  /// @dev Earliest trading-resumption timestamp; stopping cancels a pending resume.
  uint256 public resumeReadyAt;
  /// @dev Single owner of position basis/versions, active claims and nominal exposure.
  Accounting.State internal _state;
  /// @dev Persistent issuer-request nonces, revocation and daily consumption.
  RedemptionAccounting.State internal _redemptions;
  /// @dev One or two fixed issuer mandates. Receipt descriptors reference these limits without copying them.
  RouteConfig[] internal _routes;
  /// @dev Per-route publication version; each refresh requires a fresh Aqua hash.
  mapping(uint256 => uint256) public strategyVersion;
  /// @dev Current shipped order hash by route.
  mapping(uint256 => bytes32) public strategyHash;
  /// @dev Only current parameters are needed on-chain; history belongs in events.
  PricingState.State internal _pricing;
  /// @dev Admission and receipt risk metadata share the Book's authority and lock.
  ClaimMarkets.State internal _claimMarkets;
  /// @notice Factory version fixed at strategy publication, invalidated on retirement.
  mapping(uint256 => uint256) public strategyFactoryVersion;

  /*//////////////////////////////////////////////////////////////
                         TRANSIENT CONTEXT
  //////////////////////////////////////////////////////////////*/

  // Transaction-local slots are owned by BookContext, shared with linked execution.

  /*//////////////////////////////////////////////////////////////
                         ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Caller or operation identity is not permitted.
  error Unauthorized();
  /// @notice A cross-contract operation is already active.
  error Busy();
  /// @notice Deployment, route or bounded governance input is invalid.
  error InvalidConfiguration();
  /// @notice Exact-fill identity, timing or normalized trade constraints fail.
  error InvalidQuote();
  /// @notice Cash, inventory, exposure, lifetime purchases or loss capacity is insufficient.
  error CapacityExceeded();
  /// @notice Router callback identity, order or lifecycle phase is invalid.
  error InvalidCallback();
  /// @notice Measured token movement or issuer output differs from the authorized transition.
  error SettlementMismatch();

  /*//////////////////////////////////////////////////////////////
                         EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice A fresh route order is prepared for vault publication to Aqua.
  event StrategyPublished(
    uint256 indexed route, bytes32 indexed orderHash, uint256 version, uint256 factoryVersion, uint256 configVersion
  );
  /// @notice Complete native issuer mandate; multipliers use 1e18, buffers and risk limits use settlement-asset raw units.
  event IssuerRouteConfigured(
    uint256 indexed route,
    address indexed base,
    address indexed adapter,
    uint256 bid,
    uint256 ask,
    uint256 buyBuffer,
    uint256 sellBuffer,
    uint256 maxExposure,
    uint256 maxPurchases,
    uint256 lossBudget,
    uint256 maxDailyRedemption
  );
  /// @notice Inventory accounting records a measured exact pair; amounts are raw token units.
  event FillSettled(
    bytes32 indexed digest,
    uint256 indexed route,
    bool buyBase,
    uint256 amountIn,
    uint256 amountOut,
    uint256 positionVersion
  );
  /// @notice Quotes are invalidated and new trading is stopped.
  event TradingStopped(uint256 configVersion);
  /// @notice An updater replacement is scheduled for the given Unix timestamp.
  event UpdaterScheduled(address indexed updater, uint256 readyAt);
  /// @notice A delayed updater replacement advances the configuration version.
  event UpdaterChanged(address indexed updater, uint256 epoch);
  /// @notice Trading resumption is scheduled for the given Unix timestamp.
  event ResumeScheduled(uint256 readyAt);
  /// @notice A delayed resumption advances the configuration version but does not refresh NAV.
  event TradingResumed(uint256 epoch);
  /// @notice Inventory shares become an issuer right; basis and entitlement are settlement-asset raw units.
  event RedemptionRequested(
    bytes32 indexed intent,
    uint256 indexed route,
    uint256 indexed id,
    uint256 shares,
    uint256 basis,
    uint256 entitlement
  );
  /// @notice Verified recovery records settlement-asset raw units and remaining underlying entitlement.
  event RedemptionRecovered(uint256 indexed route, uint256 indexed id, uint256 cash, uint256 remaining);
  /// @notice New issuer requests are irreversibly disabled at an advanced request epoch.
  event KeeperRevoked(uint256 epoch);

  /*//////////////////////////////////////////////////////////////
                         CONSTRUCTION
  //////////////////////////////////////////////////////////////*/

  /// @notice Bind deterministic deployment addresses without mutable initialization.
  /// @dev Vault/Executor may be deployed next by the same scripted deployer. Their
  /// addresses and authorities are immutable; a deployment script must verify all
  /// three bindings before publishing any address or accepting deposits.
  constructor(Config memory c, RouteConfig[] memory routes) {
    if (
      c.vault == address(0) || c.executor == address(0) || c.vault == c.executor || c.vault == address(this)
        || c.executor == address(this) || c.asset.code.length == 0 || c.aqua.code.length == 0
        || c.router.code.length == 0 || c.updater == address(0) || c.governor == address(0) || c.guardian == address(0)
        || c.feeRecipient == address(0) || c.feeRecipient == address(this) || c.feeRecipient == c.router
        || c.feeRecipient == c.aqua || c.feeBps > 100 || c.maxParameterAge == 0
        || c.maxParameterAge > (block.chainid == 560048 ? 100 days : 1 days) || routes.length == 0 || routes.length > 2
        || c.governanceDelay < 1 days || c.governanceDelay > 30 days || c.keeper == address(0)
    ) revert InvalidConfiguration();
    if (address(SwapVM(payable(c.router)).AQUA()) != c.aqua) {
      revert InvalidConfiguration();
    }
    // Dependency getters check bindings, not code provenance. Deployment must
    // verify the pinned router implementation and exercise its canonical program.
    ASSET = c.asset;
    ASSET_UNIT = AssetUnits.unit(c.asset);
    if (c.curve.capacity < ASSET_UNIT) revert InvalidConfiguration();
    AQUA = c.aqua;
    ROUTER = c.router;
    GOVERNOR = c.governor;
    GUARDIAN = c.guardian;
    KEEPER = c.keeper;
    parameterUpdater = c.updater;
    configVersion = 1;
    PricingMath.validateCurve(c.curve);
    FACE_CAP = c.curve.capacity;
    TARGET_UTILIZATION = c.curve.target;
    CAPACITY_PENALTY = c.curve.kappa;
    FEE_RECIPIENT = c.feeRecipient;
    FEE_BPS = c.feeBps;
    CASH_BUFFER = c.cashBuffer;
    MAX_PARAMETER_AGE = c.maxParameterAge;
    MAX_MARK_AGE = c.maxMarkAge;
    MAX_EXPOSURE = c.maxBasisExposure;
    GOVERNANCE_DELAY = c.governanceDelay;
    INVENTORY_ROUTES = routes.length;
    uint256 units;
    for (uint256 i; i < routes.length; ++i) {
      RouteConfig memory r = routes[i];
      if (
        r.base.code.length == 0 || r.base == c.asset || r.adapter == address(0) || r.bid == 0 || r.bid > 1e18
          || r.ask < r.bid || r.ask > 2e18 || r.maxExposure == 0 || r.maxExposure > c.maxBasisExposure
          || r.maxPurchases == 0 || r.lossBudget == 0 || r.maxDailyRedemption == 0
      ) revert InvalidConfiguration();
      if (i != 0 && (routes[0].base == r.base || routes[0].adapter == r.adapter)) revert InvalidConfiguration();
      units |= AssetUnits.unit(r.base) << (64 * i);
      _routes.push(r);
      emit IssuerRouteConfigured(
        i,
        r.base,
        r.adapter,
        r.bid,
        r.ask,
        r.buyBuffer,
        r.sellBuffer,
        r.maxExposure,
        r.maxPurchases,
        r.lossBudget,
        r.maxDailyRedemption
      );
    }
    BASE_UNITS = units;
    VAULT = HarborVault(c.vault);
    EXECUTOR = HarborExecutor(c.executor);
    if (c.feeRecipient == address(VAULT) || c.feeRecipient == address(EXECUTOR)) revert InvalidConfiguration();
  }

  /*//////////////////////////////////////////////////////////////
                         VAULT COORDINATION
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IHarborBook
  function beginVaultOperation(bytes32 context) external {
    if (msg.sender != address(VAULT)) revert Unauthorized();
    _open(context, Operation.VAULT);
  }

  function isIdle() external view returns (bool) {
    return Context.operation() == Operation.NONE;
  }

  /// @notice Only the selected recovery/export may mutate adapter cash while locked.
  function claimOperationAllowed(address adapter, bytes32 id) external view returns (bool) {
    return Context.operation() == Operation.RECOVERY && adapter == address(uint160(Context.get(Context.CLAIM_ADAPTER)))
      && id == bytes32(Context.get(Context.CLAIM_ID)) && id != bytes32(0);
  }

  /// @inheritdoc IHarborBook
  function finishVaultOperation(bytes32 context) external {
    if (msg.sender != address(VAULT) || Context.operation() != Operation.VAULT || context != Context.context()) {
      revert Unauthorized();
    }
    _release();
  }

  /*//////////////////////////////////////////////////////////////
                         INTERNAL COORDINATION
  //////////////////////////////////////////////////////////////*/

  /// @dev Acquire the shared Book lock before calling the immutable Vault.
  /// @param context Nonzero identity used to bind every subsequent callback.
  /// @param operation Domain whose settlement methods may run while locked.
  function _open(bytes32 context, Operation operation) internal {
    if (Context.operation() != Operation.NONE) revert Busy();
    if (context == 0) revert InvalidCallback();
    Context.control(operation, Context.Phase.IDLE, false);
    Context.set(Context.CONTEXT, uint256(context));
    VAULT.beginBookOperation(context, operation);
  }

  /// @dev Release the Vault first, then clear every transient field explicitly.
  /// Same-transaction sequential operations must not inherit earlier context.
  function _release() internal {
    VAULT.finishBookOperation(Context.context());
    Context.clear();
  }
}
