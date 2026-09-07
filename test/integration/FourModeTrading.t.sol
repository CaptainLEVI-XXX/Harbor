// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {TradingFixture} from "test/helpers/TradingFixture.sol";

/// @title FourModeTradingTest
/// @notice Official settlement through the real Book, Executor and pooled vault.
contract FourModeTradingTest is TradingFixture {
  function test_TraderSellsExactInput() public {
    _assertTrade(Side.BUY_BASE, AmountMode.EXACT_IN);
  }

  function test_TraderSellsExactOutput() public {
    _assertTrade(Side.BUY_BASE, AmountMode.EXACT_OUT);
  }

  function test_TraderBuysExactInput() public {
    _buy(0, 2 ether);
    _assertTrade(Side.SELL_BASE, AmountMode.EXACT_IN);
  }

  function test_TraderBuysExactOutput() public {
    _buy(0, 2 ether);
    _assertTrade(Side.SELL_BASE, AmountMode.EXACT_OUT);
  }

  function test_TwoRoutesCannotSpendSameCash() public {
    _buy(0, 16 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(1, Side.BUY_BASE, AmountMode.EXACT_IN, 16 ether);
    vm.expectRevert(HarborBook.CapacityExceeded.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertEq(book.getPosition(1).shares, 0);
  }

  function test_PendingWithdrawalBlocksPurchasesButAllowsInventorySales() public {
    _buy(0, 2 ether);
    vm.prank(alice);
    vault.requestRedeem(1 ether * 1e6, alice, alice);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(1, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    vm.expectRevert(HarborBook.CapacityExceeded.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    _assertTrade(Side.SELL_BASE, AmountMode.EXACT_OUT);
  }

  function test_QuoteIsStaticAndMatchesExactRouterAmounts() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_OUT, 1 ether);
    uint256 version = book.portfolioVersion();
    (uint256 ai, uint256 ao) = executor.quoteFill(t, f, sig, order);
    assertEq(ai, f.routerIn);
    assertEq(ao, f.routerOut);
    assertFalse(book.usedQuoteNonce(f.epoch, f.nonce));
    assertEq(book.portfolioVersion(), version);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertTrue(book.usedQuoteNonce(f.epoch, f.nonce));
  }

  function test_SignerAndPolicyAreIndependentlyRequired() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    policy.approve(book.fillDigest(t, f), false);
    vm.expectRevert(HarborBook.PolicyNotApproved.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    policy.approve(book.fillDigest(t, f), true);
    sig[0] = bytes1(uint8(sig[0]) ^ 1);
    vm.expectRevert(HarborBook.InvalidSignature.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
  }

  function test_LateFeeFailureRollsBackEverything() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    uint256 version = book.portfolioVersion();
    vm.mockCallRevert(
      address(weth), abi.encodeWithSignature("transfer(address,uint256)", feeRecipient, f.fee), "fee payout failed"
    );
    vm.expectRevert();
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertFalse(book.usedQuoteNonce(f.epoch, f.nonce));
    assertFalse(book.usedTraderNonce(trader, t.nonce));
    assertEq(book.portfolioVersion(), version);
    assertEq(book.getPosition(0).shares, 0);
    assertEq(weth.balanceOf(address(vault)), 20 ether);
    assertEq(bases[0].balanceOf(trader), 100 ether);
    assertEq(bases[0].allowance(address(executor), address(router)), 0);
    vm.clearMockedCalls();
    vm.prank(trader);
    executor.execute(t, f, sig, order);
  }

  function test_ExecutorDonationsAreNotSweptOrUsed() public {
    weth.mint(address(executor), 3 ether);
    bases[0].mint(address(executor), 4 ether);
    _buy(0, 1 ether);
    assertEq(weth.balanceOf(address(executor)), 3 ether);
    assertEq(bases[0].balanceOf(address(executor)), 4 ether);
  }

  function test_OldQuoteFailsAfterPortfolioChange() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    _buy(1, 1 ether);
    vm.expectRevert(HarborBook.InvalidQuote.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
  }

  function test_OnlyTraderMayExecute() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    vm.expectRevert(HarborExecutor.UnauthorizedTrader.selector);
    executor.execute(t, f, sig, order);
  }

  function _assertTrade(Side side, AmountMode mode) private {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) = _quote(0, side, mode, 1 ether);
    uint256 beforeWeth = weth.balanceOf(trader);
    uint256 beforeBase = bases[0].balanceOf(trader);
    uint256 beforeFee = weth.balanceOf(feeRecipient);
    uint256 beforeCash = weth.balanceOf(address(vault));
    vm.prank(trader);
    (uint256 input, uint256 output) = executor.execute(t, f, sig, order);
    assertEq(input, f.traderIn);
    assertEq(output, f.traderOut);
    if (side == Side.BUY_BASE) {
      assertEq(weth.balanceOf(trader), beforeWeth + output);
      assertEq(bases[0].balanceOf(trader), beforeBase - input);
      assertEq(weth.balanceOf(address(vault)), beforeCash - f.routerOut);
    } else {
      assertEq(weth.balanceOf(trader), beforeWeth - input);
      assertEq(bases[0].balanceOf(trader), beforeBase + output);
      assertEq(weth.balanceOf(address(vault)), beforeCash + f.routerIn);
    }
    assertEq(weth.balanceOf(feeRecipient), beforeFee + f.fee);
    assertEq(weth.balanceOf(address(executor)), 0);
    assertEq(bases[0].balanceOf(address(executor)), 0);
    assertEq(vault.maxDeposit(alice), 0);
    vault.checkpointValuation();
  }
}
