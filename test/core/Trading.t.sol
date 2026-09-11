// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {BookState} from "src/book/base/BookState.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {Trade, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingParameters} from "src/types/PricingTypes.sol";
import {TradingFixture} from "test/base/TradingFixture.sol";
import {RealizationLogs} from "test/base/RealizationLogs.sol";
import {DirectSettlementChecks} from "test/base/DirectSettlementChecks.sol";
import {HoodiDemoChecks} from "test/base/HoodiDemoChecks.sol";

/// @notice Actual Aqua/SwapVM settlement with reusable, bounded route parameters.
contract StandingTradingTest is TradingFixture {
  function test_TwoRoutesCannotSpendSameCash() public {
    uint256 snapshot = vm.snapshotState();
    new DirectSettlementChecks().checkTwoPoolsAndZeroFee();
    vm.revertToState(snapshot);
    _buy(0, 16 ether);
    (Trade memory t,) = _quote(1, Side.BUY_BASE, AmountMode.EXACT_IN, 16 ether);
    vm.expectRevert();
    vm.prank(trader);
    executor.execute(address(book), t);
    assertEq(book.getPosition(1).shares, 0);

    // Fund enough actual cash to cross the capacity curve's 60% threshold.
    // The same standing publication must then quote less for the next purchase.
    weth.mint(alice, 800 ether);
    vm.startPrank(alice);
    weth.approve(address(vault), 800 ether);
    vault.deposit(800 ether, alice);
    vm.stopPrank();
    vault.refreshStrategy(0);
    bases[0].mint(trader, 600 ether);
    Trade memory small = _trade(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether, 0);
    uint256 beforePrice = executor.quote(address(book), small).traderOut;
    t = _trade(0, Side.BUY_BASE, AmountMode.EXACT_IN, 600 ether, 0);
    FillAmounts memory priced = executor.quote(address(book), t);
    uint256 cashBefore = weth.balanceOf(address(vault));
    vm.prank(trader);
    executor.execute(address(book), t);
    assertEq(weth.balanceOf(address(vault)), cashBefore - priced.routerOut);
    assertEq(book.faceExposure(), 616 ether);
    assertLt(executor.quote(address(book), small).traderOut, beforePrice);
    small.limitAmount = beforePrice;
    vm.expectRevert();
    vm.prank(trader);
    executor.execute(address(book), small); // Slippage, not a portfolio nonce, rejects the old expectation.
    assertEq(book.faceExposure(), 616 ether);
  }

  function test_PublicationIsBoundedVersionedAndIndependentOfNav() public {
    uint256 beforeDemo = vm.snapshotState();
    new HoodiDemoChecks().check();
    vm.revertToState(beforeDemo);
    PricingParameters memory p = book.pricingParameters(0);
    ++p.version;
    vm.prank(trader);
    vm.expectRevert(BookState.Unauthorized.selector);
    book.publishPricing(0, p);
    p.discount = 0.9e18;
    vm.expectRevert(BookState.InvalidQuote.selector);
    book.publishPricing(0, p);
    p.discount = 1e18;
    p.configVersion += 1;
    vm.expectRevert(BookState.InvalidQuote.selector);
    book.publishPricing(0, p);
    p.configVersion -= 1;
    (Trade memory old,) = _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    _buy(0, 1 ether);
    (Trade memory t,) = _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    vm.prank(trader);
    executor.execute(address(book), t); // Invalidates cached NAV.
    uint256 nav = vault.totalAssets();
    (,, bool fresh) = vault.valuationIdentity();
    assertFalse(fresh);
    book.publishPricing(0, p);
    (,, fresh) = vault.valuationIdentity();
    assertFalse(fresh);
    assertEq(vault.totalAssets(), nav);
    vm.expectRevert(BookState.InvalidQuote.selector);
    executor.quote(address(book), old);
    vm.expectRevert(BookState.InvalidQuote.selector);
    book.publishPricing(0, p); // Version replay.
    p.version += 1;
    p.observedAt = vm.getBlockTimestamp() + 1;
    vm.expectRevert(BookState.InvalidQuote.selector);
    book.publishPricing(0, p);
  }

  function test_LateFeeFailureRollsBackEverything() public {
    uint256 snapshot = vm.snapshotState();
    new DirectSettlementChecks().checkRollbackAndCallBinding();
    vm.revertToState(snapshot);
    (Trade memory t, FillAmounts memory f) = _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    uint256 version = book.getPosition(t.route).version;
    vm.mockCallRevert(
      address(weth),
      abi.encodeWithSignature("transferFrom(address,address,uint256)", address(vault), feeRecipient, f.fee),
      "fee payout failed"
    );
    vm.expectRevert();
    vm.prank(trader);
    executor.execute(address(book), t);
    assertEq(book.getPosition(t.route).version, version);
    assertEq(book.faceExposure(), 0);
    assertEq(book.getPosition(0).shares, 0);
    assertEq(weth.balanceOf(address(vault)), 20 ether);
    assertEq(bases[0].balanceOf(trader), 100 ether);
    assertEq(bases[0].allowance(address(executor), address(router)), 0);
    vm.clearMockedCalls();
    vm.prank(trader);
    executor.execute(address(book), t);
    assertEq(book.faceExposure(), 1 ether);
  }

  function test_StandingParametersSurviveTwoTradesAndAutomaticCheckpoint() public {
    (Trade memory t, FillAmounts memory f) = _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    uint256 version = book.pricingParameters(0).version;
    vm.prank(trader);
    executor.execute(address(book), t);
    (,, bool fresh) = vault.valuationIdentity();
    assertFalse(fresh);
    assertEq(abi.encode(executor.quote(address(book), t)), abi.encode(f));
    vm.prank(trader);
    executor.execute(address(book), t); // Same intent, no signature/nonce or intervening publisher.
    assertEq(book.getPosition(0).shares, 2 ether);
    assertEq(book.pricingParameters(0).version, version);
    assertEq(weth.balanceOf(address(vault)), 18.02 ether);
    assertEq(book.faceExposure(), 2 ether);
  }

  function test_OnlyTraderMayExecute() public {
    (Trade memory t,) = _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    vm.expectRevert(HarborExecutor.UnauthorizedTrader.selector);
    executor.execute(address(book), t);
    t.receiver = address(0x5555);
    uint256 beforeBalance = weth.balanceOf(t.receiver);
    vm.prank(trader);
    executor.execute(address(book), t);
    assertEq(weth.balanceOf(t.receiver) - beforeBalance, 0.98901 ether);
  }

  function test_StandingProgramSettlesAllFourModes() public {
    uint256 snapshot = vm.snapshotState();
    new DirectSettlementChecks().checkModesAndReceipts();
    vm.revertToState(snapshot);
    vm.recordLogs();
    _execute(Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    _execute(Side.BUY_BASE, AmountMode.EXACT_OUT, 1 ether);
    _execute(Side.SELL_BASE, AmountMode.EXACT_IN, 1 ether);
    _execute(Side.SELL_BASE, AmountMode.EXACT_OUT, 1 ether);
    assertEq(book.getPosition(0).shares, 0);
    assertEq(book.faceExposure(), 0);
    (uint256 gains,, uint256 count) = RealizationLogs.totals(vm.getRecordedLogs(), address(book), 0);
    assertGt(gains, 0);
    assertEq(count, 2);
  }

  function test_ExpiryAndUpdaterRevocationDoNotBlockFundedLpClaims() public {
    vm.prank(alice);
    vault.requestRedeem(10 ether * 1e6, alice, alice);
    vault.fulfillWithdrawals(1);
    uint256 credit = vault.maxWithdraw(alice);
    (Trade memory t,) = _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    book.revokeUpdater();
    vm.expectRevert(BookState.InvalidQuote.selector);
    executor.quote(address(book), t);
    vm.prank(alice);
    vault.withdraw(credit, alice, alice);
    assertEq(weth.balanceOf(alice), credit);
    book.scheduleUpdater(address(this));
    vm.warp(vm.getBlockTimestamp() + 1 days);
    book.applyUpdater();
    valuation.setObservedAt(vm.getBlockTimestamp());
    _publish(0, 1e18);
    t = _trade(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether, 0);
    vm.warp(vm.getBlockTimestamp() + 60);
    assertGt(executor.quote(address(book), t).traderOut, 0); // Inclusive parameter expiry.
    ++t.deadline;
    vm.warp(vm.getBlockTimestamp() + 1);
    valuation.setObservedAt(vm.getBlockTimestamp()); // Isolate parameter expiry from mark age.
    vm.expectRevert(BookState.InvalidQuote.selector);
    executor.quote(address(book), t);
  }

  function _execute(Side side, AmountMode mode, uint256 amount) private {
    (Trade memory t, FillAmounts memory f) = _quote(0, side, mode, amount);
    assertEq(abi.encode(executor.quote(address(book), t)), abi.encode(f));
    bool buy = side == Side.BUY_BASE;
    _assertRouterQuote(t, f);
    uint256 cash = amount * (buy ? 99 : 101) / 100;
    uint256 traderCash = buy ? cash - cash * 10 / 10000 : cash + cash * 10 / 9990;
    uint256 fee = buy ? cash - traderCash : traderCash - cash;
    uint256 beforeCash = weth.balanceOf(address(vault));
    uint256 beforeTrader = weth.balanceOf(trader);
    uint256 beforeBase = bases[0].balanceOf(trader);
    uint256 beforeFee = weth.balanceOf(feeRecipient);
    vm.prank(trader);
    executor.execute(address(book), t);
    assertEq(weth.balanceOf(address(vault)), buy ? beforeCash - cash : beforeCash + cash);
    assertEq(weth.balanceOf(trader), buy ? beforeTrader + traderCash : beforeTrader - traderCash);
    assertEq(bases[0].balanceOf(trader), buy ? beforeBase - amount : beforeBase + amount);
    assertEq(weth.balanceOf(feeRecipient), beforeFee + fee);
    assertEq(weth.balanceOf(address(executor)), 0);
    assertEq(bases[0].balanceOf(address(executor)), 0);
  }
}
