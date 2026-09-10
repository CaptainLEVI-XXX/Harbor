// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {IHarborValuation} from "src/interfaces/IHarborValuation.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {PricingMath} from "src/libraries/PricingMath.sol";
import {QuoteValidation} from "src/libraries/QuoteValidation.sol";
import {Trade, FillAmounts, Side, RouteConfig} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingCurve, PricingMarket} from "src/types/PricingTypes.sol";

/// @title StandingPricing
/// @notice Read-only live-state pricing and economic gates, linked into the Book.
/// @dev Explicit storage references preserve one accounting owner. Fixed compiler
/// linkage, not a mutable dispatch target; direct library calls have no authority.
library StandingPricing {
  struct Config {
    address vault;
    address executor;
    address weth;
    address aqua;
    address router;
    address feeRecipient;
    IHarborValuation valuation;
    uint256 nativeRoutes;
    uint256 feeBps;
    uint256 cashBuffer;
    uint256 maxExposure;
    uint256 maxMarkAge;
    PricingCurve curve;
  }
  error InvalidQuote();
  error CapacityExceeded();

  /// @notice Compute the executable pair against independently verified live inputs.
  function quote(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    Trade memory t,
    PricingPolicy memory policy,
    uint256 discount,
    uint256 factoryVersion,
    bytes32 orderHash,
    Config memory c
  ) public view returns (FillAmounts memory a) {
    RouteConfig memory r = ClaimMarkets.config(markets, routes, t.route);
    bool buy = t.side == Side.BUY_BASE;
    if (
      t.tokenIn != (buy ? r.base : c.weth) || t.tokenOut != (buy ? c.weth : r.base)
        || !_recipient(c, t.trader, r.adapter) || !_recipient(c, t.receiver, r.adapter) || t.trader == c.feeRecipient
        || t.receiver == c.feeRecipient
    ) revert InvalidQuote();
    _requireLiveValuation(book, markets, routes, c);
    PricingMarket memory m;
    m.policy = policy;
    m.discount = discount;
    m.exposure = BookPortfolio.face(book, markets, routes, c.valuation, c.nativeRoutes, c.vault);
    m.receipt = markets.markets[t.route].factory != address(0);
    if (m.receipt) {
      m.numerator = IHarborClaim(r.base).entitlement();
      m.denominator = 1;
      m.maxQuantity = 1;
    } else {
      (m.numerator, m.denominator) = c.valuation.conversion(r.base);
      // The initial inventory adapters represent 18-decimal native-denominated
      // shares. Wider ratios/denominations require a separately reviewed adapter.
      if (
        m.numerator == 0 || m.denominator == 0 || m.numerator > 1e36 || m.denominator > 1e36
          || m.numerator * 2 < m.denominator || m.numerator > m.denominator * 4
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
    a = PricingMath.quote(t, c.curve, m, c.feeBps);
    uint256 quantity = buy ? a.routerIn : a.routerOut;
    uint256 cash = buy ? a.routerOut : a.routerIn;
    (uint256 nominal, uint256 mark, uint256 time,,, bool valid) =
      BookPortfolio.observation(markets, routes, c.valuation, t.route, quantity);
    if (
      !valid || time == 0 || time > block.timestamp || block.timestamp - time > c.maxMarkAge
        || nominal != Math.fullMulDiv(quantity, m.numerator, m.denominator)
    ) revert InvalidQuote();
    QuoteValidation.price(
      t.side, cash, m.receipt ? mark : nominal, buy ? r.bid : r.ask, buy ? r.buyBuffer : r.sellBuffer
    );
    if (m.receipt) {
      BookPortfolio.receiptCheck(markets, t.route, buy, quantity, cash, factoryVersion, c.weth);
    }
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
    address spent = buy ? c.weth : r.base;
    uint256 debit = buy ? cash : quantity;
    (uint256 allocation,) = IAqua(c.aqua).safeBalances(c.vault, c.router, orderHash, spent, buy ? r.base : c.weth);
    if (debit > allocation || debit > IERC20(spent).allowance(c.vault, c.aqua)) revert CapacityExceeded();
  }

  /// @dev Use independent live marks, not the stale cached NAV left by an earlier
  /// trade. LP entry/fulfillment still requires a coherent vault checkpoint.
  function _requireLiveValuation(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    Config memory c
  ) private view {
    BookPortfolio.Value memory v = BookPortfolio.valuation(
      book, markets, routes, c.valuation, c.nativeRoutes, c.vault, false
    );
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
