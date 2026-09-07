// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IMakerHooks} from "@1inch/swap-vm/src/interfaces/IMakerHooks.sol";
import {IExtruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapQuery, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {SwapVM} from "@1inch/swap-vm/src/SwapVM.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {IHarborValuation} from "src/interfaces/IHarborValuation.sol";
import {IHarborPolicyReceiver} from "src/interfaces/IHarborPolicyReceiver.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {RedemptionAccounting} from "src/libraries/RedemptionAccounting.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {QuoteHash} from "src/libraries/QuoteHash.sol";
import {HarborProgram} from "src/swapvm/HarborProgram.sol";
import {HarborExtruction} from "src/swapvm/HarborExtruction.sol";
import {Trade, FillTerms, RouteConfig, Side, AmountMode, Operation, RedeemIntent} from "src/types/HarborTypes.sol";

/// @title HarborBook
/// @notice One vault's immutable route mandate and authenticated four-mode settlement.
/// @dev Accounting is internal-library backed. Public observations and independent
/// permits are required; neither the signer nor receiver may choose NAV or custody.
contract HarborBook is IHarborBook, IExtruction, IMakerHooks {
  using Accounting for Accounting.State;
  using RedemptionAccounting for RedemptionAccounting.State;

  struct Config {
    address vault;
    address executor;
    address weth;
    address aqua;
    address router;
    address signer;
    address governor;
    address guardian;
    address keeper;
    address receiver;
    address valuation;
    address feeRecipient;
    uint256 feeBps;
    uint256 cashBuffer;
    uint256 maxQuoteAge;
    uint256 maxMarkAge;
    uint256 depositCap;
    uint256 governanceDelay;
  }

  address public immutable WETH;
  address public immutable AQUA;
  address public immutable ROUTER;
  address public immutable GOVERNOR;
  address public immutable GUARDIAN;
  address public immutable KEEPER;
  IHarborPolicyReceiver public immutable RECEIVER;
  IHarborValuation public immutable VALUATION;
  address public immutable FEE_RECIPIENT;
  uint256 public immutable FEE_BPS;
  uint256 public immutable CASH_BUFFER;
  uint256 public immutable MAX_QUOTE_AGE;
  uint256 public immutable MAX_MARK_AGE;
  uint256 public immutable MAX_EXPOSURE;
  uint256 public immutable GOVERNANCE_DELAY;
  HarborVault public immutable VAULT;
  HarborExecutor public immutable EXECUTOR;

  address public quoteSigner;
  uint256 public quoteEpoch;
  bool public stopped;
  address public pendingSigner;
  uint256 public signerReadyAt;
  uint256 public resumeReadyAt;
  Accounting.State private _state;
  RedemptionAccounting.State private _redemptions;
  mapping(bytes32 => uint256) private _protocolIds;
  RouteConfig[] private _routes;
  mapping(uint256 => uint256) public strategyVersion;
  mapping(uint256 => bytes32) public strategyHash;
  mapping(uint256 => mapping(uint256 => bool)) public usedQuoteNonce;
  mapping(address => mapping(uint256 => bool)) public usedTraderNonce;

  /// @dev Compiler transient slots are disjoint from persistent library state.
  /// Book coordinates all domains; these locks survive begin-method returns.
  Operation private transient _operation;
  bytes32 private transient _context;
  bytes32 private transient _beforePortfolio;
  uint256 private transient _phase;
  bytes32 private transient _digest;
  bytes32 private transient _hookHash;
  uint256 private transient _beforeIn;
  uint256 private transient _beforeOut;
  uint256 private transient _route;
  bool private transient _buy;
  uint256 private transient _cash;

  error Unauthorized();
  error Busy();
  error InvalidConfiguration();
  error InvalidQuote();
  error InvalidSignature();
  error PolicyNotApproved();
  error CapacityExceeded();
  error InvalidCallback();
  error SettlementMismatch();

  event StrategyRegistered(uint256 indexed route, bytes32 indexed orderHash, uint256 version);
  event FillSettled(
    bytes32 indexed digest,
    uint256 indexed route,
    bool buyBase,
    uint256 amountIn,
    uint256 amountOut,
    uint256 portfolioVersion
  );
  event TradingStopped(uint256 quoteEpoch);
  event SignerScheduled(address indexed signer, uint256 readyAt);
  event SignerChanged(address indexed signer, uint256 epoch);
  event ResumeScheduled(uint256 readyAt);
  event TradingResumed(uint256 epoch);
  event RedemptionRequested(
    bytes32 indexed intent,
    uint256 indexed route,
    uint256 indexed id,
    uint256 shares,
    uint256 basis,
    uint256 entitlement
  );
  event RedemptionRecovered(uint256 indexed route, uint256 indexed id, uint256 cash, uint256 remaining);
  event KeeperRevoked(uint256 epoch);

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

  function route(uint256 id) external view returns (RouteConfig memory) {
    return _routes[id];
  }

  function getPosition(uint256 id) external view returns (Accounting.Position memory) {
    return _state.positions[id];
  }

  function portfolioVersion() external view returns (uint256) {
    return _state.version;
  }

  function redemptionEpoch() external view returns (uint256) {
    return _redemptions.epoch;
  }

  function usedRedemptionNonce(uint256 epoch, uint256 nonce) external view returns (bool) {
    return _redemptions.usedNonce[epoch][nonce];
  }

  function getClaim(address adapter, uint256 id) external view returns (ClaimAccounting.Claim memory) {
    return _state.claims.claims[ClaimAccounting.key(adapter, id)];
  }

  /// @notice Irreversibly revoke new keeper requests; existing recovery stays open.
  function revokeKeeper() external {
    if (msg.sender != GOVERNOR && msg.sender != GUARDIAN) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    _redemptions.revoked = true;
    emit KeeperRevoked(++_redemptions.epoch);
  }

  function requestRedemption(RedeemIntent calldata intent, uint256[] calldata amounts)
    external
    returns (IHarborAdapter.Request[] memory requests)
  {
    if (msg.sender != KEEPER || stopped) revert Unauthorized();
    RouteConfig storage r = _routes[intent.route];
    bytes32 context =
      _redemptions.consume(intent, amounts, address(VAULT), r.adapter, _state.positions[intent.route].version);
    if (intent.shares > _state.positions[intent.route].shares || _state.claims.active.length + amounts.length > 64) {
      revert CapacityExceeded();
    }
    _open(context, Operation.REDEMPTION);
    _route = intent.route;
    _cash = intent.shares;
    IHarborAdapter adapter = IHarborAdapter(r.adapter);
    if (
      adapter.BOOK() != address(this) || adapter.VAULT() != address(VAULT) || adapter.BASE() != r.base
        || adapter.WETH() != WETH
    ) revert InvalidConfiguration();
    uint256 previousBalance = SafeTransfer.balanceOf(r.base, r.adapter);
    VAULT.transferForRedemption(context);
    requests = adapter.request(amounts, previousBalance);
    if (requests.length != amounts.length) revert SettlementMismatch();
    uint256 underlying;
    for (uint256 i; i < requests.length; ++i) {
      IHarborAdapter.Request memory request = requests[i];
      if (request.shares != amounts[i] || request.id == 0) revert SettlementMismatch();
      bytes32 key = ClaimAccounting.key(r.adapter, request.id);
      uint256 basis = _state.request(intent.route, request.shares, key, request.entitlement);
      _protocolIds[key] = request.id;
      underlying += request.entitlement;
      emit RedemptionRequested(context, intent.route, request.id, request.shares, basis, request.entitlement);
    }
    _redemptions.record(intent.route, underlying, intent.minUnderlying, r.maxDailyRedemption);
    VAULT.settleIssuer(context, 0);
    _release();
  }

  function redemptionTransfer(bytes32 context)
    external
    view
    returns (address base, address adapter, uint256 amount, uint256 managed)
  {
    if (msg.sender != address(VAULT) || _operation != Operation.REDEMPTION || context != _context) {
      revert Unauthorized();
    }
    return (_routes[_route].base, _routes[_route].adapter, _cash, _state.positions[_route].shares);
  }

  /// @notice Permissionless recovery independent of signer, keeper, CRE and NAV.
  function claimRedemptions(uint256 routeId, uint256[] calldata ids, uint256[] calldata hints) external {
    if (ids.length == 0 || ids.length > 8 || ids.length != hints.length) revert InvalidConfiguration();
    address adapter = _routes[routeId].adapter;
    _open(keccak256(abi.encode(msg.sender, routeId, ids, hints)), Operation.RECOVERY);
    uint256 total;
    for (uint256 i; i < ids.length; ++i) {
      // Strict ordering rejects duplicates before any issuer interaction for that ID.
      if (i != 0 && ids[i] <= ids[i - 1]) revert InvalidConfiguration();
      bytes32 key = ClaimAccounting.key(adapter, ids[i]);
      ClaimAccounting.Claim storage c = _state.claims.claims[key];
      if (!c.exists || c.closed || c.route != routeId) revert InvalidConfiguration();
      uint256 beforeBalance = SafeTransfer.balanceOf(WETH, address(VAULT));
      (uint256 cash, uint256 remaining) = IHarborAdapter(adapter).claim(ids[i], hints[i]);
      if (SafeTransfer.balanceOf(WETH, address(VAULT)) != beforeBalance + cash) revert SettlementMismatch();
      _state.recover(key, cash, remaining);
      total += cash;
      emit RedemptionRecovered(routeId, ids[i], cash, remaining);
    }
    VAULT.settleIssuer(_context, total);
    _release();
  }

  function hasManagedPositions() external view returns (bool) {
    if (_state.claims.active.length != 0) return true;
    for (uint256 i; i < _routes.length; ++i) {
      if (_state.positions[i].shares != 0) return true;
    }
    return false;
  }

  function currentOrder(uint256 id) public view returns (ISwapVM.Order memory) {
    return _order(id, strategyVersion[id]);
  }

  function beginVaultOperation(bytes32 context) external {
    if (msg.sender != address(VAULT)) revert Unauthorized();
    _open(context, Operation.VAULT);
    _beforePortfolio = VAULT.portfolioHash();
  }

  function finishVaultOperation(bytes32 context) external {
    if (msg.sender != address(VAULT) || _operation != Operation.VAULT || context != _context) revert Unauthorized();
    if (VAULT.portfolioHash() != _beforePortfolio) ++_state.version;
    _release();
  }

  function beginTrade(bytes32 tradeHash) external {
    if (msg.sender != address(EXECUTOR)) revert Unauthorized();
    _open(tradeHash, Operation.TRADE);
    _phase = 1;
  }

  function finishTrade(bytes32 digest) external {
    if (msg.sender != address(EXECUTOR) || _operation != Operation.TRADE || _phase != 5 || digest != _digest) {
      revert Unauthorized();
    }
    VAULT.settleTrade(_context, _buy, _cash);
    _release();
  }

  function prepareStrategyFromVault(uint256 id, address requester)
    external
    returns (ISwapVM.Order memory order, bytes32 previous, address base, uint256 managed)
  {
    if (msg.sender != address(VAULT) || _operation != Operation.VAULT || requester != GOVERNOR) {
      revert Unauthorized();
    }
    previous = strategyHash[id];
    uint256 version = ++strategyVersion[id];
    order = _order(id, version);
    base = _routes[id].base;
    managed = _state.positions[id].shares;
    strategyHash[id] = keccak256(abi.encode(order));
    ++quoteEpoch;
    emit StrategyRegistered(id, strategyHash[id], version);
  }

  function stopTrading() external {
    if (msg.sender != GUARDIAN && msg.sender != GOVERNOR) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    stopped = true;
    resumeReadyAt = 0;
    ++quoteEpoch;
    VAULT.invalidateValuation();
    emit TradingStopped(quoteEpoch);
  }

  function scheduleSigner(address signer) external {
    _governance();
    if (signer == address(0)) revert InvalidConfiguration();
    pendingSigner = signer;
    signerReadyAt = block.timestamp + GOVERNANCE_DELAY;
    emit SignerScheduled(signer, signerReadyAt);
  }

  function applySigner() external {
    if (_operation != Operation.NONE) revert Busy();
    if (signerReadyAt == 0 || block.timestamp < signerReadyAt) revert Unauthorized();
    quoteSigner = pendingSigner;
    pendingSigner = address(0);
    signerReadyAt = 0;
    ++quoteEpoch;
    emit SignerChanged(quoteSigner, quoteEpoch);
  }

  function scheduleResume() external {
    _governance();
    if (!stopped) revert InvalidConfiguration();
    resumeReadyAt = block.timestamp + GOVERNANCE_DELAY;
    emit ResumeScheduled(resumeReadyAt);
  }

  function resumeTrading() external {
    if (_operation != Operation.NONE) revert Busy();
    if (resumeReadyAt == 0 || block.timestamp < resumeReadyAt) revert Unauthorized();
    resumeReadyAt = 0;
    stopped = false;
    ++quoteEpoch;
    emit TradingResumed(quoteEpoch);
  }

  function valuation()
    external
    view
    returns (uint256 inventory, uint256 claims, uint256 observedAt, uint256 policyVersion, bool valid)
  {
    observedAt = block.timestamp;
    valid = !stopped;
    for (uint256 i; i < _routes.length; ++i) {
      (uint256 entitlement, uint256 mark, uint256 time, uint256 policy,, bool ok) =
        VALUATION.inventory(_routes[i].base, _state.positions[i].shares);
      inventory += mark;
      if (time < observedAt) observedAt = time;
      if (i == 0) policyVersion = policy;
      valid = valid && ok && policy == policyVersion && mark <= entitlement;
    }
    for (uint256 i; i < _state.claims.active.length; ++i) {
      bytes32 key = _state.claims.active[i];
      ClaimAccounting.Claim storage c = _state.claims.claims[key];
      (uint256 mark, uint256 time, uint256 policy, bool ok) =
        VALUATION.claim(_routes[c.route].adapter, _protocolIds[key], c.remaining);
      claims += mark;
      if (time < observedAt) observedAt = time;
      valid = valid && ok && policy == policyVersion && mark <= c.remaining;
    }
  }

  function validate(Trade calldata trade, FillTerms calldata terms, bytes calldata signature)
    external
    view
    returns (bytes32)
  {
    if (_operation != Operation.NONE) revert Busy();
    return _validate(trade, terms, signature);
  }

  function extruction(
    bool isStaticContext,
    uint256 nextPC,
    SwapQuery calldata query,
    SwapRegisters calldata registers,
    bytes calldata args,
    bytes calldata payload
  ) external returns (uint256, uint256, SwapRegisters memory) {
    if (msg.sender != ROUTER || query.maker != address(VAULT) || query.taker != address(EXECUTOR)) {
      revert InvalidCallback();
    }
    if (payload.length > 4096) revert InvalidQuote();
    (Trade memory trade, FillTerms memory terms, bytes memory signature) =
      abi.decode(payload, (Trade, FillTerms, bytes));
    if (keccak256(payload) != keccak256(abi.encode(trade, terms, signature))) revert InvalidQuote();
    (uint256 id, uint256 version) = HarborExtruction.decode(args);
    if (
      id != trade.route || version != terms.strategyVersion || query.orderHash != terms.orderHash
        || query.tokenIn != trade.tokenIn || query.tokenOut != trade.tokenOut
        || query.isExactIn != (trade.mode == AmountMode.EXACT_IN)
    ) revert InvalidQuote();
    if (isStaticContext) {
      if (_operation != Operation.NONE) revert Busy();
    } else if (_operation != Operation.TRADE || _phase != 1 || _context != QuoteHash.tradeHash(trade)) {
      revert InvalidCallback();
    }
    bytes32 digest = _validate(trade, terms, signature);
    SwapRegisters memory result = HarborExtruction.complete(registers, query.isExactIn, terms.routerIn, terms.routerOut);
    if (!isStaticContext) {
      usedQuoteNonce[terms.epoch][terms.nonce] = true;
      usedTraderNonce[trade.trader][trade.nonce] = true;
      _digest = digest;
      _phase = 2;
      _hookHash = keccak256(
        abi.encode(
          query.maker, query.taker, query.tokenIn, query.tokenOut, terms.routerIn, terms.routerOut, query.orderHash
        )
      );
      _beforeIn = SafeTransfer.balanceOf(query.tokenIn, address(VAULT));
      _beforeOut = SafeTransfer.balanceOf(query.tokenOut, address(VAULT));
      _route = id;
      _buy = trade.side == Side.BUY_BASE;
      _cash = _buy ? terms.routerOut : terms.routerIn;
    }
    return (nextPC, payload.length, result);
  }

  function preTransferIn(address, address, address, address, uint256, uint256, bytes32, bytes calldata, bytes calldata)
    external
    pure
  {
    revert InvalidCallback();
  }

  function postTransferIn(
    address m,
    address t,
    address ti,
    address to,
    uint256 ai,
    uint256 ao,
    uint256 fee,
    bytes32 hash,
    bytes calldata md,
    bytes calldata td
  ) external {
    _hook(m, t, ti, to, ai, ao, hash, md, td, 2);
    if (fee != 0 || SafeTransfer.balanceOf(ti, address(VAULT)) != _beforeIn + ai) revert SettlementMismatch();
    _phase = 3;
  }

  function preTransferOut(
    address m,
    address t,
    address ti,
    address to,
    uint256 ai,
    uint256 ao,
    bytes32 hash,
    bytes calldata md,
    bytes calldata td
  ) external {
    _hook(m, t, ti, to, ai, ao, hash, md, td, 3);
    _phase = 4;
  }

  function postTransferOut(
    address m,
    address t,
    address ti,
    address to,
    uint256 ai,
    uint256 ao,
    uint256 fee,
    bytes32 hash,
    bytes calldata md,
    bytes calldata td
  ) external {
    _hook(m, t, ti, to, ai, ao, hash, md, td, 4);
    if (fee != 0 || SafeTransfer.balanceOf(to, address(VAULT)) != _beforeOut - ao) revert SettlementMismatch();
    if (_buy) _state.buy(_route, ai, ao);
    else _state.sell(_route, ao, ai);
    _phase = 5;
    emit FillSettled(_digest, _route, _buy, ai, ao, _state.version);
  }

  function _validate(Trade memory t, FillTerms memory f, bytes memory signature) private view returns (bytes32 digest) {
    if (stopped || t.route >= _routes.length || signature.length > 1024 || signature.length == 0) {
      revert InvalidQuote();
    }
    RouteConfig storage r = _routes[t.route];
    if (
      t.trader == r.adapter || t.receiver == r.adapter || t.trader == AQUA || t.receiver == AQUA
        || t.trader == address(RECEIVER) || t.receiver == address(RECEIVER)
    ) revert InvalidQuote();
    Accounting.Position storage p = _state.positions[t.route];
    if (
      f.vault != address(VAULT) || f.adapter != r.adapter || f.adapterVersion != 1
        || f.strategyVersion != strategyVersion[t.route] || f.orderHash == 0 || f.orderHash != strategyHash[t.route]
        || f.epoch != quoteEpoch || usedQuoteNonce[f.epoch][f.nonce] || usedTraderNonce[t.trader][t.nonce]
        || f.portfolioVersion != _state.version || f.positionVersion != p.version || f.policyVersion != 1
        || f.feeRecipient != FEE_RECIPIENT || f.feeBps != FEE_BPS || block.timestamp > t.deadline
        || f.validUntil > t.deadline || block.timestamp > f.validUntil || f.observedAt > block.timestamp
        || f.observedAt == 0 || f.validUntil < f.observedAt || f.validUntil - f.observedAt > MAX_QUOTE_AGE
    ) revert InvalidQuote();
    bool buy = t.side == Side.BUY_BASE;
    if (t.tokenIn != (buy ? r.base : WETH) || t.tokenOut != (buy ? WETH : r.base)) revert InvalidQuote();
    uint256 quantity = buy ? f.routerIn : f.routerOut;
    uint256 cash = buy ? f.routerOut : f.routerIn;
    if (buy) {
      uint256 totalExposure;
      for (uint256 i; i < _routes.length; ++i) {
        totalExposure += Accounting.exposure(_state.positions[i]);
      }
      if (
        cash > VAULT.tradingCash(CASH_BUFFER) || Accounting.exposure(p) + cash > r.maxExposure
          || totalExposure + cash > MAX_EXPOSURE || p.purchases + cash > r.maxPurchases
          || p.realizedLosses >= r.lossBudget
      ) revert CapacityExceeded();
    } else {
      if (quantity > p.shares || SafeTransfer.balanceOf(r.base, address(VAULT)) < p.shares) revert CapacityExceeded();
      uint256 basis = quantity == p.shares ? p.basis : Math.fullMulDiv(p.basis, quantity, p.shares);
      if (basis > cash && (p.realizedLosses >= r.lossBudget || basis - cash > r.lossBudget - p.realizedLosses)) {
        revert CapacityExceeded();
      }
    }
    digest = EXECUTOR.validateQuote(t, f, signature, quoteSigner);
    if (!RECEIVER.isApproved(digest)) revert PolicyNotApproved();
  }

  function _order(uint256 id, uint256 version) private view returns (ISwapVM.Order memory) {
    if (version == 0 || version > type(uint64).max) revert InvalidConfiguration();
    return HarborProgram.build(address(VAULT), address(this), WETH, _routes[id].base, id, version, uint64(version));
  }

  function _governance() private view {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
  }

  function _open(bytes32 context, Operation operation) private {
    if (_operation != Operation.NONE) revert Busy();
    if (context == 0) revert InvalidCallback();
    _operation = operation;
    _context = context;
    VAULT.beginBookOperation(context, operation);
  }

  function _release() private {
    VAULT.finishBookOperation(_context);
    _operation = Operation.NONE;
    _context = 0;
    _beforePortfolio = 0;
    _phase = 0;
    _digest = 0;
    _hookHash = 0;
    _beforeIn = 0;
    _beforeOut = 0;
    _route = 0;
    _buy = false;
    _cash = 0;
  }

  function _hook(
    address m,
    address t,
    address ti,
    address to,
    uint256 ai,
    uint256 ao,
    bytes32 hash,
    bytes calldata md,
    bytes calldata td,
    uint256 phase
  ) private view {
    if (
      msg.sender != ROUTER || _operation != Operation.TRADE || _phase != phase || md.length != 0 || td.length != 0
        || keccak256(abi.encode(m, t, ti, to, ai, ao, hash)) != _hookHash
    ) revert InvalidCallback();
  }
}
