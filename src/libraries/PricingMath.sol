// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {Trade, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingCurve, PricingMarket} from "src/types/PricingTypes.sol";
import {Amounts} from "src/libraries/Amounts.sol";
import {Fees} from "src/libraries/Fees.sol";

/// @title PricingMath
/// @notice Standing bid/ask pricing with a convex FACE inventory penalty.
/// @dev Work at 1e36 utilization precision and cash raw units * 1e18 price precision,
/// then round once at the cash boundary. Potential bounds include intermediate
/// rounding; subtracting separately rounded wei potentials is not conservative.
library PricingMath {
  uint256 internal constant WAD = 1e18;
  uint256 internal constant PRECISION = 1e36;
  uint256 internal constant MAX_AMOUNT = 1e27;
  uint256 internal constant MIN_SLOPE = 0.1e18;

  error InvalidPricingDomain();
  error UnfillableAmount();

  /// @dev Quote-local constants shared by every candidate in the inverse search.
  /// Coefficients and beforeLow retain the original directed rounding, not a
  /// rounded cash price. No external calls or state changes occur during reuse.
  struct CashContext {
    uint256 threshold;
    uint256 coefficientLow;
    uint256 coefficientHigh;
    uint256 beforeLow;
  }

  /// @notice Validate fixed curve bounds; at most 100 bisections cover MAX_AMOUNT.
  function validateCurve(PricingCurve memory c) internal pure {
    // Capacity is raw settlement units, not a fixed-point factor. Book enforces
    // at least one whole asset; the kernel only requires a positive denominator.
    if (c.capacity == 0 || c.capacity > MAX_AMOUNT || c.target > 0.9e18 || c.kappa > 0.01e18) {
      revert InvalidPricingDomain();
    }
  }

  /// @notice Enforce monotonicity with room for sub-wei arithmetic error.
  function validatePolicy(PricingPolicy memory p, PricingCurve memory c) public pure {
    if (
      p.minDiscount < 0.5e18 || p.minDiscount > p.maxDiscount || p.maxDiscount > WAD || p.buyMargin > 0.05e18
        || p.sellMargin > 0.05e18 || p.buyCost > WAD || p.sellCost > WAD
        || p.minDiscount < p.buyMargin + c.kappa + MIN_SLOPE
    ) revert InvalidPricingDomain();
  }

  /// @notice Calculate all four customer modes with native VM fee rounding.
  /// @dev Cash-specified receipt modes must equal the one-unit standing price.
  /// Exact-output chooses the least input; exact-input chooses the most output.
  function quote(Trade memory t, PricingCurve memory c, PricingMarket memory m, uint256 feeBps)
    public
    pure
    returns (FillAmounts memory a)
  {
    bool buy = t.side == Side.BUY_BASE;
    bool exactIn = t.mode == AmountMode.EXACT_IN;
    uint256 specified = t.amountSpecified;
    if (buy && !exactIn) specified = Fees.grossForNet(specified, feeBps);
    if (!buy && exactIn) specified = Fees.net(specified, feeBps);
    (uint256 input, uint256 output) = quoteCore(buy, exactIn, specified, c, m);
    uint256 coreCash = buy ? output : input;
    if (buy) output = Fees.net(output, feeBps);
    else input = exactIn ? t.amountSpecified : Fees.grossForNet(input, feeBps);
    if (m.receipt && buy && !exactIn && output != t.amountSpecified) revert UnfillableAmount();
    if (m.receipt && !buy && exactIn && Fees.grossForNet(coreCash, feeBps) != input) revert UnfillableAmount();
    a = Amounts.normalize(t, input, output);
    if (buy) {
      a.routerOut = coreCash;
      a.fee = coreCash - output;
    } else {
      a.routerIn = coreCash;
      a.fee = input - coreCash;
    }
  }

  /// @notice Price VM registers after FeeProtocol has normalized the specified amount.
  /// @dev No fee calculation or customer-limit check occurs here. The canonical
  /// program and executor enforce those after the native fee instruction unwinds.
  /// Receipt cash modes return the whole lot's canonical pair; the instruction
  /// must validate that pair against the actual specified register and intent.
  function quoteCore(bool buy, bool exactIn, uint256 specified, PricingCurve memory c, PricingMarket memory m)
    public
    pure
    returns (uint256 input, uint256 output)
  {
    validateCurve(c);
    validatePolicy(m.policy, c);
    return quoteConfigured(buy, exactIn, specified, c, m);
  }

  /// @notice Price an admitted Book curve/policy; market state is still checked live.
  /// @dev BookState validates the immutable curve; PricingState.configure validates
  /// each write-once policy. Generic callers needing validation use quoteCore.
  function quoteConfigured(bool buy, bool exactIn, uint256 specified, PricingCurve memory c, PricingMarket memory m)
    public
    pure
    returns (uint256 input, uint256 output)
  {
    if (
      m.discount < m.policy.minDiscount || m.discount > m.policy.maxDiscount || m.numerator == 0 || m.denominator == 0
        || m.maxQuantity == 0 || m.maxQuantity > MAX_AMOUNT || m.exposure > 2 * c.capacity
        || (buy && m.exposure >= c.capacity)
        || (!buy && m.discount + m.policy.sellMargin < _slope(c, m.exposure) + MIN_SLOPE)
    ) revert InvalidPricingDomain();
    if (specified == 0 || (m.receipt && m.maxQuantity != 1)) revert UnfillableAmount();
    CashContext memory ctx = _constants(c);
    (ctx.beforeLow,) = _potential(c, m.exposure, ctx);
    if (buy) {
      if (exactIn) {
        input = specified;
        output = _cash(c, m, input, true, ctx);
      } else {
        output = m.receipt ? _cash(c, m, 1, true, ctx) : specified;
        input = m.receipt ? 1 : _quantity(c, m, output, true, ctx);
      }
    } else {
      if (!exactIn) {
        output = specified;
        input = _cash(c, m, output, false, ctx);
      } else {
        input = m.receipt ? _cash(c, m, 1, false, ctx) : specified;
        output = m.receipt ? 1 : _quantity(c, m, input, false, ctx);
      }
    }
    if (input == 0 || output == 0) revert UnfillableAmount();
  }

  /// @notice Gross vault buy debit or net sell receipt for exact raw base units.
  /// @dev A zero bid means decline. Costs price operations; they are not payouts.
  /// Caller supplies the admitted curve/policy and exposure <=2K, as quoteCore does.
  function cash(PricingCurve memory c, PricingMarket memory m, uint256 quantity, bool buy)
    internal
    pure
    returns (uint256)
  {
    if (quantity == 0) return 0;
    CashContext memory ctx = _constants(c);
    (ctx.beforeLow,) = _potential(c, m.exposure, ctx);
    return _cash(c, m, quantity, buy, ctx);
  }

  /// @dev Caller fixes the curve and initial exposure for the entire search.
  function _cash(PricingCurve memory c, PricingMarket memory m, uint256 quantity, bool buy, CashContext memory ctx)
    private
    pure
    returns (uint256)
  {
    if (quantity == 0) return 0;
    if (quantity > m.maxQuantity || (m.receipt && quantity != 1)) revert UnfillableAmount();
    uint256 face = Math.fullMulDiv(quantity, m.numerator, m.denominator);
    if (face == 0 || face > MAX_AMOUNT) return 0;
    uint256 value;
    uint256 penalty;
    if (buy) {
      if (face > c.capacity - m.exposure) revert UnfillableAmount();
      (, uint256 afterHigh) = _potential(c, m.exposure + face, ctx);
      penalty = afterHigh - ctx.beforeLow + m.policy.buyCost * WAD;
      value = face * (m.discount - m.policy.buyMargin);
      return value > penalty ? (value - penalty) / WAD : 0;
    }
    if (face > m.exposure) revert UnfillableAmount();
    (, uint256 remainingHigh) = _potential(c, m.exposure - face, ctx);
    // A lower bound on the released penalty makes the ask conservative.
    penalty = ctx.beforeLow > remainingHigh ? ctx.beforeLow - remainingHigh : 0;
    value = face * (m.discount + m.policy.sellMargin) + m.policy.sellCost * WAD;
    if (value <= penalty) revert UnfillableAmount();
    return Math.divUp(value - penalty, WAD);
  }

  /// @notice Lower/upper bounds on Phi(x), in settlement-asset raw units * 1e18.
  /// @dev x <= 2K, K <= 1e27 and target <= .9 bound every intermediate. At
  /// these bounds the interval is far below one wei; a >= .1 unit slope keeps
  /// integer cash functions nondecreasing despite the approximation interval.
  function potential(PricingCurve memory c, uint256 x) internal pure returns (uint256 low, uint256 high) {
    if (c.kappa == 0 || x * WAD <= c.capacity * c.target) return (0, 0);
    return _potential(c, x, _constants(c));
  }

  function _constants(PricingCurve memory c) private pure returns (CashContext memory ctx) {
    if (c.kappa == 0) return ctx;
    ctx.threshold = c.target * WAD;
    uint256 denominator = 3 * (WAD - c.target) ** 2;
    ctx.coefficientLow = _mulDiv(c.kappa, 1e54, denominator);
    ctx.coefficientHigh = _mulDivUp(c.kappa, 1e54, denominator);
  }

  function _potential(PricingCurve memory c, uint256 x, CashContext memory ctx)
    private
    pure
    returns (uint256 low, uint256 high)
  {
    if (c.kappa == 0 || x * WAD <= c.capacity * c.target) return (0, 0);
    uint256 lo = _mulDiv(x, PRECISION, c.capacity) - ctx.threshold;
    uint256 hi = _mulDivUp(x, PRECISION, c.capacity) - ctx.threshold;
    uint256 cubeLow = _mulDiv(_mulDiv(lo, lo, PRECISION), lo, PRECISION);
    uint256 cubeHigh = _mulDivUp(_mulDivUp(hi, hi, PRECISION), hi, PRECISION);
    low = _mulDiv(c.capacity, _mulDiv(cubeLow, ctx.coefficientLow, PRECISION), WAD);
    high = _mulDivUp(c.capacity, _mulDivUp(cubeHigh, ctx.coefficientHigh, PRECISION), WAD);
  }

  /// @dev Continuous marginal penalty, rounded up, in 1e18 units per FACE unit.
  function _slope(PricingCurve memory c, uint256 x) private pure returns (uint256) {
    if (c.kappa == 0 || x * WAD <= c.capacity * c.target) return 0;
    uint256 excess = _mulDivUp(x, PRECISION, c.capacity) - c.target * WAD;
    uint256 square = _mulDivUp(excess, excess, PRECISION);
    return _mulDivUp(c.kappa, square, (WAD - c.target) ** 2);
  }

  /// @dev Monotone integer search, bounded by the 90-bit quantity domain.
  function _quantity(PricingCurve memory c, PricingMarket memory m, uint256 target, bool buy, CashContext memory ctx)
    private
    pure
    returns (uint256)
  {
    uint256 maximum = _cash(c, m, m.maxQuantity, buy, ctx);
    if (target == 0 || target > maximum) revert UnfillableAmount();
    uint256 lo;
    uint256 hi = m.maxQuantity;
    while (lo < hi) {
      uint256 mid = buy ? lo + (hi - lo) / 2 : lo + (hi - lo + 1) / 2;
      uint256 value = _cash(c, m, mid, buy, ctx);
      if (buy) {
        if (value >= target) hi = mid;
        else lo = mid + 1;
      } else {
        if (value <= target) lo = mid;
        else hi = mid - 1;
      }
    }
    if (lo == 0) revert UnfillableAmount();
    return lo;
  }

  /// @dev Bounds for both helpers: validateCurve fixes
  /// K <= 1e27, target <= .9e18, kappa <= .01e18; quoteConfigured requires x <= 2K.
  /// Thus excess <= 2e36, its square <= 4e72, and the cubing product <= 8e72.
  /// The coefficient product <= 1e70 and cube*coefficient < 4e72. Every product
  /// fits uint256 (8e72 < 2^256); divisors are positive K, 1e36, 1e18 or
  /// 3*(1e18-target)^2. The rounded quotient fits too. Only curve internals use
  /// these helpers: unconstrained token conversions retain fullMulDiv.
  /// No memory, storage or external-call effects; no intentional wraparound.
  function _mulDiv(uint256 x, uint256 y, uint256 d) private pure returns (uint256 z) {
    assembly ("memory-safe") { z := div(mul(x, y), d) }
  }

  /// @dev Same proven domain as _mulDiv. Add one iff the product has a remainder;
  /// do not form product+d-1, which has a different overflow domain.
  function _mulDivUp(uint256 x, uint256 y, uint256 d) private pure returns (uint256 z) {
    assembly ("memory-safe") {
      let product := mul(x, y)
      z := add(div(product, d), iszero(iszero(mod(product, d))))
    }
  }
}
