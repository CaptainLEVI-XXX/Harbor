// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {PricingMath} from "src/libraries/PricingMath.sol";
import {PricingState} from "src/libraries/PricingState.sol";
import {QuoteValidation} from "src/libraries/QuoteValidation.sol";
import {Trade, FillAmounts, Side, AmountMode, RouteConfig} from "src/types/HarborTypes.sol";
import {PricingParameters, PricingCurve, PricingMarket} from "src/types/PricingTypes.sol";

/// @title StandingPricing
/// @notice Read-only live-state pricing and economic gates, linked into the Book.
/// @dev Explicit storage references preserve one accounting owner. Fixed compiler
/// linkage, not a mutable dispatch target; direct library calls have no authority.
library StandingPricing {
  struct Config {
    address vault;
    address executor;
    address asset;
    address aqua;
    address router;
    address feeRecipient;
    uint256 nativeRoutes;
    uint256 feeBps;
    uint256 cashBuffer;
    uint256 maxExposure;
    uint256 maxMarkAge;
    PricingCurve curve;
    bool vmPricing;
    uint256 specified;
    bool stopped;
    address updater;
    uint256 configVersion;
    uint256 assetUnit;
    uint256 baseUnit;
  }
  error InvalidQuote();
  error CapacityExceeded();

  /// @notice Compute the executable pair against independently verified live inputs.
  function quote(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    PricingState.State storage pricing,
    mapping(uint256 => uint256) storage strategyVersions,
    mapping(uint256 => bytes32) storage strategyHashes,
    mapping(uint256 => uint256) storage factoryVersions,
    Trade memory t,
    Config memory c
  ) public view returns (FillAmounts memory a, BookPortfolio.Value memory value, bytes32 evidence) {
    PricingParameters memory p = pricing.parameters[t.route];
    bytes32 orderHash = strategyHashes[t.route];
    uint256 factoryVersion = factoryVersions[t.route];
    if (
      c.stopped || c.updater == address(0) || t.route >= c.nativeRoutes + markets.count || p.version == 0
        || t.pricingVersion != p.version || t.configVersion != c.configVersion || p.configVersion != c.configVersion
        || t.strategyVersion != strategyVersions[t.route] || orderHash == 0 || block.timestamp > t.deadline
        || block.timestamp > p.validUntil
    ) revert InvalidQuote();
    RouteConfig memory r = ClaimMarkets.config(markets, routes, t.route);
    bool buy = t.side == Side.BUY_BASE;
    if (
      t.tokenIn != (buy ? r.base : c.asset) || t.tokenOut != (buy ? c.asset : r.base)
        || !_recipient(c, t.trader, r.adapter) || !_recipient(c, t.receiver, r.adapter) || t.trader == c.feeRecipient
        || t.receiver == c.feeRecipient
    ) revert InvalidQuote();
    value = _requireLiveValuation(book, markets, routes, c);
    PricingMarket memory m;
    m.policy = PricingState.loadPolicy(pricing, t.route);
    m.discount = p.discount;
    // The live valuation has checked each fixed native adapter's cash asset;
    // registered receipts reference those same source adapters.
    (m.exposure, m.numerator, m.denominator) =
      BookPortfolio.faceAndConversion(book, markets, routes, c.nativeRoutes, c.vault, t.route);
    m.receipt = markets.markets[t.route].factory != address(0);
    if (m.receipt) {
      if (t.trader == markets.markets[t.route].factory || t.receiver == markets.markets[t.route].factory) {
        revert InvalidQuote();
      }
      // Registration fixes the whole right's nominal face, not its mutable mark.
      // The live observation below must still match this face before authorization.
      m.numerator = markets.markets[t.route].nominal;
      m.denominator = 1;
      m.maxQuantity = 1;
    } else {
      // Compare whole tokens, not raw units: a six-decimal settlement token
      // and eighteen-decimal share must not be mistaken for a near-zero price.
      // Both units <=1e18 and n,d <=1e36, so these products fit uint256.
      if (
        m.numerator == 0 || m.denominator == 0 || m.numerator > 1e36 || m.denominator > 1e36
          || m.numerator * c.baseUnit * 2 < m.denominator * c.assetUnit
          || m.numerator * c.baseUnit > m.denominator * c.assetUnit * 4
      ) revert InvalidQuote();
      if (buy) {
        if (m.exposure >= c.curve.capacity) revert CapacityExceeded();
        // Largest raw quantity whose floored entitlement fits the FACE headroom.
        uint256 held = book.positions[t.route].shares;
        uint256 heldFace = Math.fullMulDiv(held, m.numerator, m.denominator);
        m.maxQuantity =
          Math.fullMulDivUp(c.curve.capacity - m.exposure + heldFace + 1, m.denominator, m.numerator) - 1 - held;
        if (m.maxQuantity > PricingMath.MAX_AMOUNT) m.maxQuantity = PricingMath.MAX_AMOUNT;
      } else {
        m.maxQuantity = book.positions[t.route].shares;
      }
    }
    if (c.vmPricing) {
      (a.routerIn, a.routerOut) =
        PricingMath.quoteConfigured(buy, t.mode == AmountMode.EXACT_IN, c.specified, c.curve, m);
    } else {
      // Preview includes fees; execution uses Extruction with FeeProtocol-normalized registers.
      a = PricingMath.quote(t, c.curve, m, c.feeBps);
    }
    uint256 quantity = buy ? a.routerIn : a.routerOut;
    uint256 cash = buy ? a.routerOut : a.routerIn;
    (uint256 nominal, uint256 mark, uint256 time,, bytes32 observed, bool valid) = m.receipt
      ? BookPortfolio.receiptCheck(markets, t.route, buy, quantity, factoryVersion)
      : BookPortfolio.observation(markets, routes, t.route, quantity);
    evidence = observed;
    if (
      !valid || time == 0 || time > block.timestamp || block.timestamp - time > c.maxMarkAge
        || nominal != Math.fullMulDiv(quantity, m.numerator, m.denominator)
    ) revert InvalidQuote();
    QuoteValidation.price(
      t.side, cash, m.receipt ? mark : nominal, buy ? r.bid : r.ask, buy ? r.buyBuffer : r.sellBuffer
    );
    BookPortfolio.capacity(
      book,
      markets,
      routes,
      c.nativeRoutes,
      t.route,
      buy,
      quantity,
      cash,
      buy ? HarborVault(c.vault).tradingCash(c.cashBuffer) : 0,
      c.maxExposure,
      c.vault
    );
    address spent = buy ? c.asset : r.base;
    uint256 debit = buy ? cash : quantity;
    (uint256 allocation, uint256 credited) =
      IAqua(c.aqua).safeBalances(c.vault, c.router, orderHash, spent, buy ? r.base : c.asset);
    uint256 inputCredit = buy ? quantity : cash;
    if (
      debit > allocation || debit > IERC20(spent).allowance(c.vault, c.aqua)
        || inputCredit > type(uint248).max - credited
    ) revert CapacityExceeded();
  }

  /// @dev Use independent live marks, not the stale cached NAV left by an earlier
  /// trade. LP entry/fulfillment still requires a coherent vault checkpoint.
  function _requireLiveValuation(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    Config memory c
  ) private view returns (BookPortfolio.Value memory v) {
    v = BookPortfolio.valuation(book, markets, routes, c.nativeRoutes, c.vault, c.asset, false);
    if (
      !v.valid || v.observedAt == 0 || v.observedAt > block.timestamp || block.timestamp - v.observedAt > c.maxMarkAge
    ) {
      revert InvalidQuote();
    }
  }

  function _recipient(Config memory c, address who, address adapter) private view returns (bool) {
    return who != address(0) && who != address(this) && who != c.vault && who != c.executor && who != c.aqua
      && who != c.router && who != adapter;
  }
}
