// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {Trade, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingCurve, PricingMarket} from "src/types/PricingTypes.sol";
import {Amounts} from "src/libraries/Amounts.sol";
import {Fees} from "src/libraries/Fees.sol";

/// @title PricingMath
/// @notice Standing bid/ask pricing with a convex FACE inventory penalty.
/// @dev Work at 1e36 utilization precision and WETH-wei * 1e18 price precision,
/// then round once at the cash boundary. Potential bounds include intermediate
/// rounding; subtracting separately rounded wei potentials is not conservative.
library PricingMath {
  uint256 internal constant WAD = 1e18;
  uint256 internal constant PRECISION = 1e36;
  uint256 internal constant MAX_AMOUNT = 1e27;
  uint256 internal constant MIN_SLOPE = 0.1e18;

  error InvalidPricingDomain();
  error UnfillableAmount();

  /// @notice Validate fixed curve bounds; at most 100 bisections cover MAX_AMOUNT.
  function validateCurve(PricingCurve memory c) internal pure {
    if (c.capacity < WAD || c.capacity > MAX_AMOUNT || c.target > 0.9e18 || c.kappa > 0.01e18) {
      revert InvalidPricingDomain();
    }
  }

  /// @notice Enforce monotonicity with room for sub-wei arithmetic error.
  function validatePolicy(PricingPolicy memory p, PricingCurve memory c) internal pure {
    if (
      p.minDiscount < 0.5e18 || p.minDiscount > p.maxDiscount || p.maxDiscount > WAD || p.buyMargin > 0.05e18
        || p.sellMargin > 0.05e18 || p.buyCost > WAD || p.sellCost > WAD
        || p.minDiscount < p.buyMargin + c.kappa + MIN_SLOPE
    ) revert InvalidPricingDomain();
  }

  /// @notice Calculate all four customer amount modes, including external fees.
  /// @dev Cash-specified receipt modes must equal the one-unit standing price.
  /// Exact-output chooses the least input; exact-input chooses the most output.
  function quote(Trade memory t, PricingCurve memory c, PricingMarket memory m, uint256 feeBps)
    public
    pure
    returns (FillAmounts memory a)
  {
    validateCurve(c);
    validatePolicy(m.policy, c);
    bool buy = t.side == Side.BUY_BASE;
    if (
      m.discount < m.policy.minDiscount || m.discount > m.policy.maxDiscount || m.numerator == 0 || m.denominator == 0
        || m.maxQuantity == 0 || m.maxQuantity > MAX_AMOUNT || m.exposure > 2 * c.capacity
        || (buy && m.exposure >= c.capacity)
        || (!buy && m.discount + m.policy.sellMargin < _slope(c, m.exposure) + MIN_SLOPE)
    ) revert InvalidPricingDomain();
    if (t.amountSpecified == 0 || (m.receipt && m.maxQuantity != 1)) revert UnfillableAmount();
    uint256 input;
    uint256 output;
    if (buy) {
      if (t.mode == AmountMode.EXACT_IN) {
        input = t.amountSpecified;
        output = Fees.net(cash(c, m, input, true), feeBps);
      } else {
        output = t.amountSpecified;
        uint256 gross = Fees.grossForNet(output, feeBps);
        input = _quantity(c, m, gross, true);
        if (m.receipt && Fees.net(cash(c, m, 1, true), feeBps) != output) revert UnfillableAmount();
      }
    } else {
      if (t.mode == AmountMode.EXACT_OUT) {
        output = t.amountSpecified;
        input = Fees.grossForNet(cash(c, m, output, false), feeBps);
      } else {
        input = t.amountSpecified;
        uint256 net = Fees.net(input, feeBps);
        output = _quantity(c, m, net, false);
        if (m.receipt && Fees.grossForNet(cash(c, m, 1, false), feeBps) != input) revert UnfillableAmount();
      }
    }
    a = Amounts.normalize(t, input, output, feeBps);
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

  /// @notice Lower/upper bounds on Phi(x), in WETH wei * 1e18.
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
