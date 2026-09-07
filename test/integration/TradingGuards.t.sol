// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {TradingFixture} from "test/helpers/TradingFixture.sol";

/// @title TradingGuardsTest
/// @notice Portfolio/nonce invalidation, reserve priority and bounded governance.
contract TradingGuardsTest is TradingFixture {
  function test_RefreshPreservesBasisAndRejectsRetiredOrder() public {
    _buy(0, 1 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    uint256 basis = book.getPosition(0).basis;
    vault.refreshStrategy(0);
    assertEq(book.getPosition(0).basis, basis);
    assertEq(book.getPosition(0).shares, 1 ether);
    vm.expectRevert(HarborBook.InvalidQuote.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
  }

  function test_OnlyGovernanceCanRefresh() public {
    vm.expectRevert(HarborBook.Unauthorized.selector);
    vm.prank(alice);
    vault.refreshStrategy(0);
  }

  function test_FundedReservesCannotBeTraded() public {
    uint256 shares = vault.balanceOf(alice);
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    vault.fulfillWithdrawals(1);
    assertEq(vault.maxWithdraw(alice), 10 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 16 ether);
    vm.expectRevert(HarborBook.CapacityExceeded.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    vm.prank(alice);
    vault.withdraw(10 ether, alice, alice);
  }

  function test_StopClosesDepositGateButPreservesFundedClaims() public {
    uint256 shares = vault.balanceOf(alice);
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    vault.fulfillWithdrawals(1);
    book.stopTrading();
    assertEq(vault.maxDeposit(bob), 0);
    vm.expectRevert(HarborVault.ValuationUnavailable.selector);
    vault.checkpointValuation();
    vm.prank(alice);
    vault.withdraw(10 ether, alice, alice);
    assertEq(weth.balanceOf(alice), 10 ether);
  }

  function test_GovernanceCannotImmediatelyResumeOrReplaceSigner() public {
    book.stopTrading();
    book.scheduleResume();
    book.scheduleSigner(address(0x999));
    vm.expectRevert(HarborBook.Unauthorized.selector);
    book.resumeTrading();
    vm.expectRevert(HarborBook.Unauthorized.selector);
    book.applySigner();
    vm.warp(1000 + 1 days);
    book.resumeTrading();
    book.applySigner();
    assertFalse(book.stopped());
    assertEq(book.quoteSigner(), address(0x999));
    assertEq(vault.maxDeposit(alice), 0); // Resume is not a fresh mark.
  }

  function test_PauseCancelsScheduledResume() public {
    book.stopTrading();
    book.scheduleResume();
    book.stopTrading();
    vm.warp(1000 + 1 days);
    vm.expectRevert(HarborBook.Unauthorized.selector);
    book.resumeTrading();
  }

  function test_RequestAfterTradeDoesNotRecombineStaleMarksAndCash() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    uint256 nav = vault.totalAssets();
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertEq(vault.totalAssets(), nav);
    vm.prank(alice);
    vault.requestRedeem(1e6, alice, alice);
    assertEq(vault.totalAssets(), nav);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 20.01 ether);
  }

  function test_SettlementNonceRemainsConsumedAcrossRefresh() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    vault.checkpointValuation();
    vault.refreshStrategy(0);
    assertTrue(book.usedQuoteNonce(f.epoch, f.nonce));
    assertTrue(book.usedTraderNonce(trader, t.nonce));
    (Trade memory newer, FillTerms memory next, bytes memory nextSig, ISwapVM.Order memory nextOrder) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    newer.nonce = t.nonce;
    nextSig = _sign(newer, next);
    vm.expectRevert(HarborBook.InvalidQuote.selector);
    vm.prank(trader);
    executor.execute(newer, next, nextSig, nextOrder);
  }
}
