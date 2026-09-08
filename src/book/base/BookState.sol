// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SwapVM} from "@1inch/swap-vm/src/SwapVM.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {HarborExactFill} from "src/swapvm/instructions/HarborExactFill.sol";
import {HarborClaimGuard} from "src/swapvm/instructions/HarborClaimGuard.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {IHarborValuation} from "src/interfaces/IHarborValuation.sol";
import {IHarborPolicyReceiver} from "src/interfaces/IHarborPolicyReceiver.sol";
import {RedemptionAccounting} from "src/libraries/RedemptionAccounting.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {RouteConfig, Operation} from "src/types/HarborTypes.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";

/// @title BookState
/// @notice Shared immutable mandate, persistent ledgers and transaction-local locks.
/// @dev Every Book module inherits this one state owner. Domain libraries use fixed
/// compiler links and explicit storage references; no mutable dispatch or manual slots.
/// Context lasts until explicit release. New deployments require fresh bindings.
abstract contract BookState is IHarborBook {
  /*//////////////////////////////////////////////////////////////
                                TYPES
  //////////////////////////////////////////////////////////////*/

  /// @notice Transaction-local progress through the input-first settlement hooks.
  /// @dev Advancing a phase never releases the Book/Vault operation lock.
  enum SettlementPhase {
    IDLE,
    OPENED,
    AUTHORIZED,
    INPUT_RECEIVED,
    OUTPUT_AUTHORIZED,
    OUTPUT_SENT
  }

  /// @notice Deployment-only mandate. Addresses and risk ceilings cannot be replaced.
  struct Config {
    /// @notice Predicted pooled maker and sole treasury address.
    address vault;
    /// @notice Predicted trader settlement entrypoint.
    address executor;
    /// @notice Approved wrapped native token; accounting uses wei.
    address weth;
    /// @notice Official Aqua balance-management deployment.
    address aqua;
    /// @notice Harbor router deployment with exact-fill and claim-guard instructions.
    address router;
    /// @notice Initial quote signer; replacement is governance-delayed.
    address signer;
    /// @notice Authority for bounded configuration operations.
    address governor;
    /// @notice Emergency stop and keeper-revocation authority.
    address guardian;
    /// @notice Only caller allowed to initiate issuer requests.
    address keeper;
    /// @notice Independent authenticated fill-permit receiver.
    address receiver;
    /// @notice Public inventory and issuer-right valuation provider.
    address valuation;
    /// @notice Fixed beneficiary of WETH-denominated trading fees.
    address feeRecipient;
    /// @notice Trading fee in basis points, at most 100.
    uint256 feeBps;
    /// @notice Unreserved cash floor in WETH wei.
    uint256 cashBuffer;
    /// @notice Maximum signed observation-to-expiry interval in seconds.
    uint256 maxQuoteAge;
    /// @notice Maximum public valuation age in seconds.
    uint256 maxMarkAge;
    /// @notice Aggregate exposure ceiling in WETH wei; vault cap is bound at deployment.
    uint256 depositCap;
    /// @notice Delay for signer rotation and trading resumption, in seconds.
    uint256 governanceDelay;
  }

  /*//////////////////////////////////////////////////////////////
                         IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @dev Approved cash asset; all cash accounting uses WETH wei.
  address public immutable WETH;
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
  /// @dev Independent permit authority; cannot set NAV or destinations.
  IHarborPolicyReceiver public immutable RECEIVER;
  /// @dev Public marks provider; not the private quote signer.
  IHarborValuation public immutable VALUATION;
  /// @dev Fixed WETH fee beneficiary.
  address public immutable FEE_RECIPIENT;
  /// @dev Trading fee in basis points.
  uint256 public immutable FEE_BPS;
  /// @dev Cash floor excluded from new purchases, in WETH wei.
  uint256 public immutable CASH_BUFFER;
  /// @dev Maximum quote observation-to-expiry interval, seconds.
  uint256 public immutable MAX_QUOTE_AGE;
  /// @dev Maximum age of public marks, seconds.
  uint256 public immutable MAX_MARK_AGE;
  /// @dev Aggregate warehouse plus pending acquisition basis ceiling, WETH wei.
  uint256 public immutable MAX_EXPOSURE;
  /// @dev Minimum delay for signer rotation or trading resumption, seconds.
  uint256 public immutable GOVERNANCE_DELAY;
  /// @dev Sole custody and LP-share accounting boundary.
  HarborVault public immutable VAULT;
  /// @dev Only caller permitted to open and finish a trade.
  HarborExecutor public immutable EXECUTOR;
  /// @notice Number of original inventory routes; receipt history is never iterated.
  uint256 public immutable INVENTORY_ROUTES;

  /*//////////////////////////////////////////////////////////////
                         PERSISTENT STATE
  //////////////////////////////////////////////////////////////*/

  /// @dev Current exact-fill signer, independently constrained by public marks and permits.
  address public quoteSigner;
  /// @dev Persistent quote invalidation version; never reset by transaction cleanup.
  uint256 public quoteEpoch;
  /// @dev Trading and fresh-mark gate; funded withdrawals and recovery remain available.
  bool public stopped;
  /// @dev Scheduled replacement signer; zero when no rotation is pending.
  address public pendingSigner;
  /// @dev Earliest signer-rotation timestamp; zero disables application.
  uint256 public signerReadyAt;
  /// @dev Earliest trading-resumption timestamp; stopping cancels a pending resume.
  uint256 public resumeReadyAt;
  /// @dev Single owner of position cost basis, active claims and portfolio version.
  Accounting.State internal _state;
  /// @dev Persistent issuer-request nonces, revocation and daily consumption.
  RedemptionAccounting.State internal _redemptions;
  /// @dev Issuer-native IDs indexed by the adapter-domain claim key.
  mapping(bytes32 => uint256) internal _protocolIds;
  /// @dev One or two fixed inventory routes followed by individually admitted receipt routes.
  RouteConfig[] internal _routes;
  /// @dev Per-route publication version; each refresh requires a fresh Aqua hash.
  mapping(uint256 => uint256) public strategyVersion;
  /// @dev Current shipped order hash by route.
  mapping(uint256 => bytes32) public strategyHash;
  /// @dev Consumed quote nonces by epoch; durable across calls and refreshes.
  mapping(uint256 => mapping(uint256 => bool)) public usedQuoteNonce;
  /// @dev Consumed trader nonces; durable across signer/strategy changes.
  mapping(address => mapping(uint256 => bool)) public usedTraderNonce;
  /// @dev Admission and receipt risk metadata share the Book's authority and lock.
  ClaimMarkets.State internal _claimMarkets;
  /// @notice Factory version fixed at strategy publication, invalidated on retirement.
  mapping(uint256 => uint256) public strategyFactoryVersion;

  /*//////////////////////////////////////////////////////////////
                         TRANSIENT CONTEXT
  //////////////////////////////////////////////////////////////*/

  /// @dev Compiler transient slots are disjoint from persistent library state.
  /// Book coordinates all domains; these locks survive begin-method returns.
  /// @dev Transaction-local domain lock shared across all inherited modules.
  Operation internal transient _operation;
  /// @dev Exact operation identity; persists across callback returns.
  bytes32 internal transient _context;
  /// @dev Vault portfolio identity before a vault-originated operation.
  bytes32 internal transient _beforePortfolio;
  /// @dev Input-first hook lifecycle; never a durable accounting value.
  SettlementPhase internal transient _phase;
  /// @dev Authorized fill digest required at final executor settlement.
  bytes32 internal transient _digest;
  /// @dev Commitment to the exact maker/taker/token/amount/order hook tuple.
  bytes32 internal transient _hookHash;
  /// @dev Maker input-token balance before router transfers, raw units.
  uint256 internal transient _beforeIn;
  /// @dev Maker output-token balance before router transfers, raw units.
  uint256 internal transient _beforeOut;
  /// @dev Active trading or issuer-request route.
  uint256 internal transient _route;
  /// @dev Whether the active trade purchases base inventory for the vault.
  bool internal transient _buy;
  /// @dev Trade cash in WETH wei; during REDEMPTION only, requested wrapped shares.
  uint256 internal transient _cash;

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
  /// @notice The configured signer did not authorize this exact digest.
  error InvalidSignature();
  /// @notice The independent receiver has no current permit for this digest.
  error PolicyNotApproved();
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
  event StrategyRegistered(uint256 indexed route, bytes32 indexed orderHash, uint256 version);
  /// @notice Inventory accounting records a measured exact pair; amounts are raw token units.
  event FillSettled(
    bytes32 indexed digest,
    uint256 indexed route,
    bool buyBase,
    uint256 amountIn,
    uint256 amountOut,
    uint256 portfolioVersion
  );
  /// @notice Quotes are invalidated and new trading is stopped.
  event TradingStopped(uint256 quoteEpoch);
  /// @notice A signer replacement is scheduled for the given Unix timestamp.
  event SignerScheduled(address indexed signer, uint256 readyAt);
  /// @notice A delayed signer replacement advances the quote epoch.
  event SignerChanged(address indexed signer, uint256 epoch);
  /// @notice Trading resumption is scheduled for the given Unix timestamp.
  event ResumeScheduled(uint256 readyAt);
  /// @notice A delayed resumption advances the quote epoch but does not refresh NAV.
  event TradingResumed(uint256 epoch);
  /// @notice Inventory shares become an issuer right; basis and entitlement are WETH wei.
  event RedemptionRequested(
    bytes32 indexed intent,
    uint256 indexed route,
    uint256 indexed id,
    uint256 shares,
    uint256 basis,
    uint256 entitlement
  );
  /// @notice Verified recovery records WETH wei and remaining underlying entitlement.
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
        || c.executor == address(this) || c.weth.code.length == 0 || c.aqua.code.length == 0
        || c.router.code.length == 0 || c.signer == address(0) || c.governor == address(0) || c.guardian == address(0)
        || c.receiver.code.length == 0 || c.valuation.code.length == 0 || c.feeRecipient == address(0)
        || c.feeRecipient == address(this) || c.feeRecipient == c.router || c.feeRecipient == c.aqua || c.feeBps > 100
        || c.maxQuoteAge == 0 || routes.length == 0 || routes.length > 2 || c.governanceDelay < 1 days
        || c.governanceDelay > 30 days || c.keeper == address(0)
    ) revert InvalidConfiguration();
    if (address(SwapVM(payable(c.router)).AQUA()) != c.aqua || address(SwapVM(payable(c.router)).WETH()) != c.weth) {
      revert InvalidConfiguration();
    }
    if (
      HarborSwapVMRouter(payable(c.router)).HARBOR_EXACT_FILL_OPCODE() != HarborExactFill.OPCODE
        || HarborSwapVMRouter(payable(c.router)).HARBOR_CLAIM_GUARD_OPCODE() != HarborClaimGuard.OPCODE
    ) {
      revert InvalidConfiguration();
    }
    WETH = c.weth;
    AQUA = c.aqua;
    ROUTER = c.router;
    GOVERNOR = c.governor;
    GUARDIAN = c.guardian;
    KEEPER = c.keeper;
    RECEIVER = IHarborPolicyReceiver(c.receiver);
    VALUATION = IHarborValuation(c.valuation);
    quoteSigner = c.signer;
    FEE_RECIPIENT = c.feeRecipient;
    FEE_BPS = c.feeBps;
    CASH_BUFFER = c.cashBuffer;
    MAX_QUOTE_AGE = c.maxQuoteAge;
    MAX_MARK_AGE = c.maxMarkAge;
    MAX_EXPOSURE = c.depositCap;
    GOVERNANCE_DELAY = c.governanceDelay;
    INVENTORY_ROUTES = routes.length;
    for (uint256 i; i < routes.length; ++i) {
      RouteConfig memory r = routes[i];
      if (
        r.base.code.length == 0 || r.base == c.weth || r.adapter == address(0) || r.bid == 0 || r.bid > 1e18
          || r.ask < r.bid || r.ask > 2e18 || r.maxExposure == 0 || r.maxExposure > c.depositCap || r.maxPurchases == 0
          || r.lossBudget == 0 || r.maxDailyRedemption == 0
      ) revert InvalidConfiguration();
      if (i != 0 && (routes[0].base == r.base || routes[0].adapter == r.adapter)) revert InvalidConfiguration();
      _routes.push(r);
    }
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
    _beforePortfolio = VAULT.portfolioHash();
  }

  /// @inheritdoc IHarborBook
  function finishVaultOperation(bytes32 context) external {
    if (msg.sender != address(VAULT) || _operation != Operation.VAULT || context != _context) revert Unauthorized();
    if (VAULT.portfolioHash() != _beforePortfolio) ++_state.version;
    _release();
  }

  /*//////////////////////////////////////////////////////////////
                         INTERNAL COORDINATION
  //////////////////////////////////////////////////////////////*/

  /// @dev Acquire the shared Book lock before calling the immutable Vault.
  /// @param context Nonzero identity used to bind every subsequent callback.
  /// @param operation Domain whose settlement methods may run while locked.
  function _open(bytes32 context, Operation operation) internal {
    if (_operation != Operation.NONE) revert Busy();
    if (context == 0) revert InvalidCallback();
    _operation = operation;
    _context = context;
    VAULT.beginBookOperation(context, operation);
  }

  /// @dev Release the Vault first, then clear every transient field explicitly.
  /// Same-transaction sequential operations must not inherit earlier context.
  function _release() internal {
    VAULT.finishBookOperation(_context);
    _operation = Operation.NONE;
    _context = 0;
    _beforePortfolio = 0;
    _phase = SettlementPhase.IDLE;
    _digest = 0;
    _hookHash = 0;
    _beforeIn = 0;
    _beforeOut = 0;
    _route = 0;
    _buy = false;
    _cash = 0;
  }
}
