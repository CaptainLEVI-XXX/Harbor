// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {Trade, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingCurve, PricingMarket} from "src/types/PricingTypes.sol";
import {Amounts} from "src/libraries/Amounts.sol";
import {Fees} from "src/libraries/Fees.sol";

/// @title PricingReference
/// @notice Straightforward precomputation-free reference for exact integer differential tests.
/// @dev Work at 1e36 utilization precision and cash raw units * 1e18 price precision,
/// then round once at the cash boundary. Potential bounds include intermediate
/// rounding; subtracting separately rounded wei potentials is not conservative.
library PricingReference {
  uint256 internal constant WAD = 1e18;
  uint256 internal constant PRECISION = 1e36;
  uint256 internal constant MAX_AMOUNT = 1e27;
  uint256 internal constant MIN_SLOPE = 0.1e18;

  error InvalidPricingDomain();
  error UnfillableAmount();

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
    if (
      m.discount < m.policy.minDiscount || m.discount > m.policy.maxDiscount || m.numerator == 0 || m.denominator == 0
        || m.maxQuantity == 0 || m.maxQuantity > MAX_AMOUNT || m.exposure > 2 * c.capacity
        || (buy && m.exposure >= c.capacity)
        || (!buy && m.discount + m.policy.sellMargin < _slope(c, m.exposure) + MIN_SLOPE)
    ) revert InvalidPricingDomain();
    if (specified == 0 || (m.receipt && m.maxQuantity != 1)) revert UnfillableAmount();
    if (buy) {
      if (exactIn) {
        input = specified;
        output = cash(c, m, input, true);
      } else {
        output = m.receipt ? cash(c, m, 1, true) : specified;
        input = m.receipt ? 1 : _quantity(c, m, output, true);
      }
    } else {
      if (!exactIn) {
        output = specified;
        input = cash(c, m, output, false);
      } else {
        input = m.receipt ? cash(c, m, 1, false) : specified;
        output = m.receipt ? 1 : _quantity(c, m, input, false);
      }
    }
    if (input == 0 || output == 0) revert UnfillableAmount();
  }

  /// @notice Gross vault buy debit or net sell receipt for exact raw base units.
  /// @dev A zero bid means decline. Costs price operations; they are not payouts.
  function cash(PricingCurve memory c, PricingMarket memory m, uint256 quantity, bool buy)
    internal
    pure
    returns (uint256)
  {
    if (quantity == 0) return 0;
    if (quantity > m.maxQuantity || (m.receipt && quantity != 1)) revert UnfillableAmount();
    uint256 face = Math.fullMulDiv(quantity, m.numerator, m.denominator);
    if (face == 0 || face > MAX_AMOUNT) return 0;
    (uint256 beforeLow,) = potential(c, m.exposure);
    uint256 value;
    uint256 penalty;
    if (buy) {
      if (face > c.capacity - m.exposure) revert UnfillableAmount();
      (, uint256 afterHigh) = potential(c, m.exposure + face);
      penalty = afterHigh - beforeLow + m.policy.buyCost * WAD;
      value = face * (m.discount - m.policy.buyMargin);
      return value > penalty ? (value - penalty) / WAD : 0;
    }
    if (face > m.exposure) revert UnfillableAmount();
    (, uint256 remainingHigh) = potential(c, m.exposure - face);
    // A lower bound on the released penalty makes the ask conservative.
    penalty = beforeLow > remainingHigh ? beforeLow - remainingHigh : 0;
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
    uint256 threshold = c.target * WAD;
    uint256 lo = Math.fullMulDiv(x, PRECISION, c.capacity) - threshold;
    uint256 hi = Math.fullMulDivUp(x, PRECISION, c.capacity) - threshold;
    uint256 denominator = 3 * (WAD - c.target) ** 2;
    uint256 coefficientLow = Math.fullMulDiv(c.kappa, 1e54, denominator);
    uint256 coefficientHigh = Math.fullMulDivUp(c.kappa, 1e54, denominator);
    uint256 cubeLow = Math.fullMulDiv(Math.fullMulDiv(lo, lo, PRECISION), lo, PRECISION);
    uint256 cubeHigh = Math.fullMulDivUp(Math.fullMulDivUp(hi, hi, PRECISION), hi, PRECISION);
    low = Math.fullMulDiv(c.capacity, Math.fullMulDiv(cubeLow, coefficientLow, PRECISION), WAD);
    high = Math.fullMulDivUp(c.capacity, Math.fullMulDivUp(cubeHigh, coefficientHigh, PRECISION), WAD);
  }

  /// @dev Continuous marginal penalty, rounded up, in 1e18 units per FACE unit.
  function _slope(PricingCurve memory c, uint256 x) private pure returns (uint256) {
    if (c.kappa == 0 || x * WAD <= c.capacity * c.target) return 0;
    uint256 excess = Math.fullMulDivUp(x, PRECISION, c.capacity) - c.target * WAD;
    uint256 square = Math.fullMulDivUp(excess, excess, PRECISION);
    return Math.fullMulDivUp(c.kappa, square, (WAD - c.target) ** 2);
  }

  /// @dev Monotone integer search, bounded by the 90-bit quantity domain.
  function _quantity(PricingCurve memory c, PricingMarket memory m, uint256 target, bool buy)
    private
    pure
    returns (uint256)
  {
    uint256 maximum = cash(c, m, m.maxQuantity, buy);
    if (target == 0 || target > maximum) revert UnfillableAmount();
    uint256 lo;
    uint256 hi = m.maxQuantity;
    while (lo < hi) {
      uint256 mid = buy ? lo + (hi - lo) / 2 : lo + (hi - lo + 1) / 2;
      uint256 value = cash(c, m, mid, buy);
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
}
