// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math as ReferenceMath} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Fees} from "src/libraries/Fees.sol";
import {Amounts} from "src/libraries/Amounts.sol";
import {Trade, Side, AmountMode, FillAmounts} from "src/types/HarborTypes.sol";

contract AmountsHarness {
  function net(uint256 g, uint256 b) external pure returns (uint256) {
    return Fees.net(g, b);
  }

  function gross(uint256 n, uint256 b) external pure returns (uint256) {
    return Fees.grossForNet(n, b);
  }

  function normalize(Trade calldata t, uint256 i, uint256 o, uint256 b) external pure returns (FillAmounts memory) {
    return Amounts.normalize(t, i, o, b);
  }
}

/// @title AmountsTest
/// @notice Reference-derived integer rounding and four-mode fee semantics.
contract AmountsTest is Test {
  AmountsHarness internal h = new AmountsHarness();

  function testFuzz_GrossUpIsExactAndMinimal(uint128 n, uint16 rate) public view {
    uint256 b = uint256(rate) % 10_000;
    uint256 g = h.gross(n, b);
    assertEq(h.net(g, b), n);
    if (n > 0) assertLt(h.net(g - 1, b), n);
    uint256 numerator = uint256(n) * 10_000; // Independent reference fits in 142 bits.
    assertEq(g, numerator / (10_000 - b) + (numerator % (10_000 - b) == 0 ? 0 : 1));
  }

  function testFuzz_NetMatchesFullWidthReference(uint256 g, uint16 rate) public view {
    uint256 b = uint256(rate) % 10_000;
    assertEq(h.net(g, b), ReferenceMath.mulDiv(g, 10_000 - b, 10_000));
  }

  function test_BothVaultBuyModesNormalizeNetOutput() public view {
    Trade memory t;
    t.side = Side.BUY_BASE;
    t.amountSpecified = 8 ether;
    t.limitAmount = 9.99 ether;
    FillAmounts memory a = h.normalize(t, 8 ether, 9.99 ether, 10);
    assertEq(a.routerIn, 8 ether);
    assertEq(a.routerOut, 10 ether);
    assertEq(a.fee, 0.01 ether);
    t.mode = AmountMode.EXACT_OUT;
    t.amountSpecified = 9.99 ether;
    t.limitAmount = 9 ether;
    FillAmounts memory b = h.normalize(t, 8 ether, 9.99 ether, 10);
    assertEq(abi.encode(a), abi.encode(b));
  }

  function test_BothVaultSellModesNormalizeGrossInput() public view {
    Trade memory t;
    t.side = Side.SELL_BASE;
    t.amountSpecified = 5.1 ether;
    t.limitAmount = 4 ether;
    FillAmounts memory a = h.normalize(t, 5.1 ether, 4 ether, 10);
    assertEq(a.routerIn, 5.0949 ether);
    assertEq(a.routerOut, 4 ether);
    assertEq(a.fee, 0.0051 ether);
    t.mode = AmountMode.EXACT_OUT;
    t.amountSpecified = 4 ether;
    t.limitAmount = 6 ether;
    FillAmounts memory b = h.normalize(t, 5.1 ether, 4 ether, 10);
    assertEq(abi.encode(a), abi.encode(b));
  }

  function test_RejectsInsufficientCapByOneWei() public {
    Trade memory t;
    t.mode = AmountMode.EXACT_OUT;
    t.amountSpecified = 1 ether;
    t.limitAmount = 2 ether - 1;
    vm.expectRevert(Amounts.LimitExceeded.selector);
    h.normalize(t, 2 ether, 1 ether, 0);
  }

  function test_RejectsNonminimalGrossExactOutput() public {
    Trade memory t;
    t.side = Side.SELL_BASE;
    t.mode = AmountMode.EXACT_OUT;
    t.amountSpecified = 1;
    t.limitAmount = 3;
    // At 50%, both gross 2 and 3 produce net 1; exact output must collect 2.
    vm.expectRevert(Amounts.InvalidFillAmounts.selector);
    h.normalize(t, 3, 1, 5000);
  }

  function test_RejectsNoninvertibleFeeAndOverflow() public {
    vm.expectRevert(abi.encodeWithSelector(Fees.InvalidFee.selector, 10_000));
    h.gross(1, 10_000);
    vm.expectRevert();
    h.gross(type(uint256).max, 1);
  }
}
