// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {PricingMath} from "src/libraries/PricingMath.sol";
import {PricingCurve, PricingMarket, PricingPolicy} from "src/types/PricingTypes.sol";
import {Trade, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {Fees} from "src/libraries/Fees.sol";

/// @notice Independent rational reference, inversion and indivisible-receipt regressions.
contract PricingTest is Test {
  function _market(uint256 x) private pure returns (PricingCurve memory c, PricingMarket memory m) {
    c = PricingCurve(1_000_000 ether, 0.6e18, 0.0025e18);
    m.policy = PricingPolicy(0.95e18, 1e18, 0.002e18, 0.002e18, 0, 0);
    m.discount = 0.99e18;
    m.exposure = x;
    m.numerator = 1;
    m.denominator = 1;
    m.maxQuantity = c.capacity - x;
  }

  function _trade(Side side, AmountMode mode, uint256 amount) private pure returns (Trade memory t) {
    t.side = side;
    t.mode = mode;
    t.amountSpecified = amount;
    t.limitAmount = mode == AmountMode.EXACT_IN ? 0 : type(uint256).max;
  }

  /// @dev Exact potential difference in WETH-wei * 1e18. This reference cubes
  /// unnormalized FACE with a shared rational denominator, not the kernel's path.
  function _delta(PricingCurve memory c, uint256 x, uint256 e, bool up) private pure returns (uint256) {
    uint256 threshold = c.capacity * 6 / 10;
    uint256 headroom = c.capacity - threshold;
    uint256 lo = x > threshold ? x - threshold : 0;
    uint256 hi = x + e > threshold ? x + e - threshold : 0;
    uint256 cubes = hi ** 3 - lo ** 3;
    return
      up ? Math.fullMulDivUp(cubes, c.kappa, 3 * headroom ** 2) : Math.fullMulDiv(cubes, c.kappa, 3 * headroom ** 2);
  }

  function testFuzz_ConservativeCurveAndMinimalInverse(uint96 exposureSeed, uint96 quantitySeed) public pure {
    uint256 x = bound(uint256(exposureSeed), 1 ether, 999_998 ether);
    (PricingCurve memory c, PricingMarket memory m) = _market(x);
    uint256 q = bound(uint256(quantitySeed), 1 ether, c.capacity - x);
    uint256 bid = PricingMath.cash(c, m, q, true);
    uint256 referenceBid = (q * 0.988e18 - _delta(c, x, q, true)) / 1e18;
    assertLe(bid, referenceBid);
    assertLe(referenceBid - bid, 1);
    if (q > 1) assertLe(PricingMath.cash(c, m, q - 1, true), bid);
    FillAmounts memory a = PricingMath.quote(_trade(Side.BUY_BASE, AmountMode.EXACT_IN, q), c, m, 10);
    assertEq(a.traderOut + a.fee, a.routerOut);
    FillAmounts memory b = PricingMath.quote(_trade(Side.BUY_BASE, AmountMode.EXACT_OUT, a.traderOut), c, m, 10);
    assertLe(b.traderIn, q);
    assertLt(PricingMath.cash(c, m, b.traderIn - 1, true), b.routerOut);

    // Reverse the acquired FACE. Same parameters must not give the customer a profit.
    m.exposure = x + q;
    m.maxQuantity = q;
    uint256 ask = PricingMath.cash(c, m, q, false);
    uint256 referenceAsk = Math.divUp(q * 0.992e18 - _delta(c, x, q, false), 1e18);
    assertGe(ask, referenceAsk);
    assertLe(ask - referenceAsk, 1);
    FillAmounts memory s = PricingMath.quote(_trade(Side.SELL_BASE, AmountMode.EXACT_OUT, q), c, m, 10);
    assertGe(s.traderIn, a.traderOut);
    assertEq(s.routerIn + s.fee, s.traderIn);
    FillAmounts memory r = PricingMath.quote(_trade(Side.SELL_BASE, AmountMode.EXACT_IN, s.traderIn), c, m, 10);
    assertEq(r.traderOut, q);
  }

  function test_WholeReceiptExactnessAndBadPolicy() public {
    (PricingCurve memory c, PricingMarket memory m) = _market(100 ether);
    m.receipt = true;
    m.numerator = 2 ether;
    m.maxQuantity = 1;
    FillAmounts memory b = PricingMath.quote(_trade(Side.BUY_BASE, AmountMode.EXACT_IN, 1), c, m, 10);
    FillAmounts memory exact = PricingMath.quote(_trade(Side.BUY_BASE, AmountMode.EXACT_OUT, b.traderOut), c, m, 10);
    assertEq(exact.traderIn, 1);
    vm.expectRevert(PricingMath.UnfillableAmount.selector);
    PricingMath.quote(_trade(Side.BUY_BASE, AmountMode.EXACT_OUT, b.traderOut - 1), c, m, 10);
    FillAmounts memory s = PricingMath.quote(_trade(Side.SELL_BASE, AmountMode.EXACT_OUT, 1), c, m, 10);
    exact = PricingMath.quote(_trade(Side.SELL_BASE, AmountMode.EXACT_IN, s.traderIn), c, m, 10);
    assertEq(exact.traderOut, 1);
    vm.expectRevert(PricingMath.UnfillableAmount.selector);
    PricingMath.quote(_trade(Side.SELL_BASE, AmountMode.EXACT_IN, s.traderIn + 1), c, m, 10);
    m.policy.minDiscount = 0;
    vm.expectRevert(PricingMath.InvalidPricingDomain.selector);
    PricingMath.quote(_trade(Side.SELL_BASE, AmountMode.EXACT_OUT, 1), c, m, 10);
  }

  function test_MaximumDomainInverseAndDust() public {
    (PricingCurve memory c, PricingMarket memory m) = _market(0);
    c.capacity = 1e27;
    m.exposure = 5e26;
    m.maxQuantity = 5e26;
    uint256 gasBefore = gasleft();
    FillAmounts memory a = PricingMath.quote(_trade(Side.BUY_BASE, AmountMode.EXACT_OUT, 4e26), c, m, 10);
    uint256 consumed = gasBefore - gasleft();
    emit log_named_uint("maximum-domain exact-output gas", consumed);
    assertLt(consumed, 2_000_000);
    assertEq(a.traderOut, 4e26);
    assertGe(PricingMath.cash(c, m, a.traderIn, true), a.routerOut);
    assertLt(PricingMath.cash(c, m, a.traderIn - 1, true), a.routerOut);
    vm.expectRevert();
    PricingMath.quote(_trade(Side.BUY_BASE, AmountMode.EXACT_IN, 1), c, m, 10);
  }
}
