// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedemptionMarketFixture} from "test/helpers/RedemptionMarketFixture.sol";
import {BookState} from "src/book/base/BookState.sol";
import {VaultState} from "src/vault/base/VaultState.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {WithdrawalQueue} from "src/libraries/WithdrawalQueue.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HarborSettlementTest
/// @notice Compact economic regressions through real Harbor, Aqua and SwapVM execution.
/// @dev Reuses synthetic issuer/mark/permit fixtures. WETH amounts are wei; LP
/// shares have a 1e6 offset. Expected payouts do not call production math helpers.
contract HarborSettlementTest is RedemptionMarketFixture {
  function testFuzz_DepositPurchaseClaimRecoveryAndLpPayout(uint96 recoverySeed) public {
    uint256 recovery = bound(uint256(recoverySeed), 0, 4.8 ether);
    // Setup: two 10 WETH deposits; the pool bought four assets at 0.99 WETH each.
    uint256 shares = 10 ether * 1e6;
    assertEq(vault.balanceOf(alice), shares);
    assertEq(vault.totalSupply(), 2 * shares);
    assertEq(weth.balanceOf(alice), 0);
    assertEq(weth.balanceOf(address(vault)), 16.04 ether);
    assertEq(bases[0].balanceOf(address(vault)), 4 ether);
    assertEq(weth.balanceOf(feeRecipient), 0.00396 ether);

    uint256 id = _request(4 ether);
    assertEq(book.getClaim(address(adapter), id).basis, 3.96 ether);
    assertEq(book.getPosition(0).pendingBasis, 3.96 ether);
    uint256 route = book.exportClaim(0, id, address(factory));
    assertTrue(book.getClaim(address(adapter), id).closed);
    assertEq(book.getPosition(0).pendingBasis, 0);
    assertEq(book.getPosition(route).basis, 3.96 ether);
    assertEq(book.claimTotals(0).purchases, 0); // Export is custody movement, not a purchase.
    assertEq(weth.balanceOf(address(vault)), 16.04 ether);
    vm.expectRevert(ClaimMarkets.InvalidReceipt.selector);
    book.exportClaim(0, id, address(factory));

    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    assertEq(vault.pendingRedeemRequest(0, alice), shares);
    assertEq(vault.maxWithdraw(alice), 0); // A request alone creates no cash credit.
    queue.setFinalized(id, recovery);
    vm.expectEmit(true, true, false, true, address(book));
    emit ClaimMarkets.ReceiptDisposed(route, 2, 3.96 ether, recovery, true);
    vm.prank(bob); // Recovery is permissionless but always pays the vault.
    book.recoverClaim(route, 1);
    assertEq(weth.balanceOf(bob), 0);
    assertEq(weth.balanceOf(address(vault)), 16.04 ether + recovery);
    assertEq(book.claimTotals(0).basis, 0);
    assertEq(book.claimTotals(0).losses, recovery < 3.96 ether ? 3.96 ether - recovery : 0);
    vm.expectRevert(BookState.InvalidConfiguration.selector);
    book.recoverClaim(route, 1);

    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 16.04 ether + recovery);
    // Virtual asset = 1 wei; virtual shares = 1e6. Funding rounds WETH down.
    uint256 payout = shares * (16.04 ether + recovery + 1) / (2 * shares + 1e6);
    (uint256 policy, uint256 marked,) = vault.valuationIdentity();
    assertNotEq(policy, marked); // Regression: the funding log must not conflate these.
    vm.expectEmit(true, true, false, true, address(vault));
    emit VaultState.WithdrawalFunded(0, alice, shares, payout, policy, marked, 0);
    vault.fulfillWithdrawals(1);
    assertEq(vault.pendingRedeemRequest(0, alice), 0);
    assertEq(vault.claimableRedeemRequest(0, alice), shares);
    assertEq(vault.maxWithdraw(alice), payout);
    assertEq(vault.totalSupply(), shares);
    vm.prank(alice);
    assertEq(vault.withdraw(payout, alice, alice), shares);
    assertEq(weth.balanceOf(alice), payout);
    assertEq(weth.balanceOf(address(vault)), 16.04 ether + recovery - payout);
    assertEq(vault.claimableRedeemRequest(0, alice), 0);
    (, uint256 reserved,,,) = vault.accountingStatus();
    assertEq(reserved, 0);
  }

  function test_CashLimitedFundingKeepsThePartialFifoHead() public {
    _request(4 ether);
    vault.checkpointValuation(); // 16.04 cash + 4.8 synthetic claim mark.
    uint256 shares = 10 ether * 1e6;
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    vm.prank(bob);
    vault.requestRedeem(shares, bob, bob);
    vault.fulfillWithdrawals(2);
    uint256 aliceCash = shares * (20.84 ether + 1) / (2 * shares + 1e6);
    assertEq(vault.maxWithdraw(alice), aliceCash);
    assertEq(vault.maxWithdraw(bob), 16.04 ether - aliceCash);
    assertEq(vault.pendingRedeemRequest(0, alice), 0);
    uint256 pending = vault.pendingRedeemRequest(0, bob);
    assertGt(pending, 0);
    assertLt(pending, shares);
    (uint256 cash, uint256 reserved,,,) = vault.accountingStatus();
    assertEq(cash, 16.04 ether);
    assertEq(reserved, cash); // Claim marks cannot back funded WETH liabilities.
    (uint256 head, uint256 tail) = vault.withdrawalQueueBounds();
    assertEq(head, 1);
    assertEq(tail, 2);
    (WithdrawalQueue.Ticket[] memory tickets, uint256 next) = vault.withdrawalTickets(head, 1);
    assertEq(next, tail);
    assertEq(tickets.length, 1);
    assertEq(tickets[0].controller, bob);
    assertEq(tickets[0].pending, pending);
    vault.fulfillWithdrawals(2);
    assertEq(vault.pendingRedeemRequest(0, bob), pending);
    assertEq(vault.maxWithdraw(bob), 16.04 ether - aliceCash);
  }

  function test_FundedCreditCannotBeStolenOverdrawnOrSpentTwice() public {
    vm.prank(alice);
    vault.requestRedeem(10 ether * 1e6, alice, alice);
    vault.fulfillWithdrawals(1);
    uint256 credit = vault.maxWithdraw(alice);
    vm.expectRevert(VaultState.Unauthorized.selector);
    vm.prank(bob);
    vault.withdraw(credit, bob, alice);
    vm.expectRevert(WithdrawalQueue.InsufficientCredit.selector);
    vm.prank(alice);
    vault.withdraw(credit + 1, alice, alice);
    assertEq(vault.maxWithdraw(alice), credit);
    assertEq(weth.balanceOf(bob), 0);
    vm.prank(alice);
    vault.withdraw(credit, alice, alice);
    vm.expectRevert(WithdrawalQueue.InsufficientCredit.selector);
    vm.prank(alice);
    vault.withdraw(credit, alice, alice);
    assertEq(weth.balanceOf(alice), credit);
    assertEq(vault.maxWithdraw(alice), 0);
  }

  function test_ReceiptReacquisitionCannotResetIssuerPurchaseOrLossBudgets() public {
    (uint256 route, uint256 id, address receipt) = _externalMarket(1 ether);
    uint256 cash = weth.balanceOf(address(vault));
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    assertEq(weth.balanceOf(address(vault)), cash - 1.164 ether); // 1.2 * 0.97.
    assertEq(IERC20(receipt).balanceOf(address(vault)), 1);
    _tradeClaim(route, Side.SELL_BASE, AmountMode.EXACT_OUT);
    assertEq(weth.balanceOf(address(vault)), cash + 0.012 ether); // Sale: 1.2 * 0.98.
    assertEq(IERC20(receipt).balanceOf(trader), 1);
    vm.prank(trader);
    IERC20(receipt).approve(address(executor), 1);
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_OUT);
    assertEq(book.getPosition(route).version, 3);
    assertEq(book.getPosition(route).purchases, 0);
    assertEq(book.claimTotals(0).basis, 1.164 ether);
    assertEq(book.claimTotals(0).purchases, 2.328 ether);
    queue.setFinalized(id, 0);
    vm.expectEmit(true, true, false, true, address(book));
    emit ClaimMarkets.ReceiptDisposed(route, 4, 1.164 ether, 0, true);
    book.recoverClaim(route, 1);
    assertEq(weth.balanceOf(address(vault)), cash + 0.012 ether - 1.164 ether);
    assertEq(book.claimTotals(0).basis, 0);
    assertEq(book.claimTotals(0).purchases, 2.328 ether);
    assertEq(book.claimTotals(0).losses, 1.164 ether);
    assertEq(book.getPosition(route).realizedLosses, 0); // Budget exists once, at issuer scope.
    assertEq(book.getPosition(route).version, 4);
    (uint256[] memory routes,) = book.activeReceiptRoutes(0, 1);
    assertEq(routes.length, 0);
  }

  function test_QuoteExpiryIsInclusiveAndSuccessfulFillConsumesNonces() public {
    (uint256 route,, address receipt) = _externalMarket(1 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    t.deadline = block.timestamp + 30;
    f.validUntil = t.deadline;
    sig = _sign(t, f);
    uint256 snapshot = vm.snapshotState();
    vm.warp(t.deadline + 1); // Marks are still fresh; expiration alone must reject.
    vm.expectRevert(BookState.InvalidQuote.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertFalse(book.usedQuoteNonce(f.epoch, f.nonce));
    assertFalse(book.usedTraderNonce(trader, t.nonce));
    assertEq(IERC20(receipt).balanceOf(trader), 1);
    assertEq(weth.balanceOf(address(vault)), 16.04 ether);
    assertTrue(vm.revertToState(snapshot));
    vm.warp(t.deadline);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertTrue(book.usedQuoteNonce(f.epoch, f.nonce));
    assertTrue(book.usedTraderNonce(trader, t.nonce));
    assertEq(IERC20(receipt).balanceOf(address(vault)), 1);
    assertEq(weth.balanceOf(address(vault)), 14.876 ether);
    vm.expectRevert(BookState.InvalidQuote.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertEq(weth.balanceOf(address(vault)), 14.876 ether);
  }

  function test_LiveDiscoverySurvivesMiddleRemovalAndUnavailableMarks() public {
    uint256 first = _request(0.5 ether);
    uint256 middle = _request(0.5 ether);
    uint256 last = _request(0.5 ether);
    queue.setFinalized(middle, 0);
    _claim(middle);
    uint256 route = book.exportClaim(0, first, address(factory));
    book.stopTrading();
    valuation.setValid(false);
    (BookPortfolio.NativeClaim[] memory claims, uint256 next) = book.activeNativeClaims(0, 1);
    assertEq(next, 1);
    assertEq(claims.length, 1);
    assertEq(claims[0].issuerId, last);
    assertEq(claims[0].basis, 0.495 ether);
    (uint256[] memory routes,) = book.activeReceiptRoutes(0, 1);
    assertEq(routes.length, 1);
    assertEq(routes[0], route);
    queue.setFinalized(last, 0.5 ether);
    _claim(claims[0].issuerId);
    queue.setFinalized(first, 0.5 ether);
    book.recoverClaim(routes[0], 1);
    assertEq(weth.balanceOf(address(vault)), 17.04 ether);
    (claims,) = book.activeNativeClaims(0, 1);
    (routes,) = book.activeReceiptRoutes(0, 1);
    assertEq(claims.length + routes.length, 0);
    vm.expectRevert(BookPortfolio.InvalidPage.selector);
    book.activeNativeClaims(0, 33);
  }

  function test_OperatorDepositChargesPayerAndCreditsChosenReceiver() public {
    vm.expectRevert(VaultState.Unauthorized.selector);
    vm.prank(trader);
    vault.mint(1e6, alice, alice);
    weth.mint(bob, 1 ether);
    vm.prank(alice);
    vault.setOperator(bob, true);
    vm.prank(bob);
    weth.approve(address(vault), 1 ether);
    uint256 shares = uint256(1 ether) * (20 ether * 1e6 + 1e6) / (20.04 ether + 1);
    vm.expectEmit(true, true, true, true, address(vault));
    emit VaultState.LiquidityIssued(bob, alice, trader, 1 ether, shares);
    vm.prank(bob);
    vault.deposit(1 ether, trader, alice);
    assertEq(weth.balanceOf(bob), 0);
    assertEq(weth.balanceOf(alice), 0);
    assertEq(weth.balanceOf(address(vault)), 17.04 ether);
    assertEq(vault.balanceOf(trader), shares);
    assertEq(vault.balanceOf(alice), 10 ether * 1e6);
  }
}
