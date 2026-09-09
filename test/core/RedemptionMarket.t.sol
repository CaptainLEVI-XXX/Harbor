// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedemptionMarketFixture} from "test/base/RedemptionMarketFixture.sol";
import {LidoClaimFactory} from "src/claims/LidoClaimFactory.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillTerms, Side, AmountMode, RedeemIntent, RouteConfig} from "src/types/HarborTypes.sol";
import {BookState} from "src/book/base/BookState.sol";
import {HarborClaimGuard} from "src/swapvm/instructions/HarborClaimGuard.sol";

contract RedemptionMarketTest is RedemptionMarketFixture {
  function test_FourModesUseActualAquaReceiptAndWethTransfers() public {
    for (uint256 i; i < 2; ++i) {
      (uint256 route,, address receipt) = _externalMarket(1 ether);
      uint256 cash = weth.balanceOf(address(vault));
      _tradeClaim(route, Side.BUY_BASE, AmountMode(i));
      assertEq(IERC20(receipt).balanceOf(address(vault)), 1);
      assertEq(IERC20(receipt).balanceOf(trader), 0);
      assertEq(weth.balanceOf(address(vault)), cash - 1.164 ether);
      assertEq(book.getPosition(route).shares, 1);
      assertEq(book.activeReceiptCount(), 1);
      (uint256 inventory, uint256 claims,,,,) = _values();
      assertEq(inventory, 4 ether);
      assertEq(claims, 1.2 ether);
      _tradeClaim(route, Side.SELL_BASE, AmountMode(i));
      assertEq(IERC20(receipt).balanceOf(trader), 1);
      assertEq(book.activeReceiptCount(), 0);
      assertEq(book.getPosition(route).basis, 0);
      assertEq(weth.balanceOf(address(vault)), cash + 0.012 ether);
      assertEq(IERC20(receipt).balanceOf(address(executor)), 0);
      assertEq(IERC20(receipt).balanceOf(address(router)), 0);
      assertEq(IERC20(receipt).allowance(address(executor), address(router)), 0);
    }
  }

  function test_ExportSellAndFinalHolderRecoversWithoutDoubleCounting() public {
    uint256 id = _request(1 ether);
    uint256 oldBasis = book.getClaim(address(adapter), id).basis;
    uint256 route = book.exportClaim(0, id, address(factory));
    address receipt = book.route(route).base;
    assertTrue(book.getClaim(address(adapter), id).closed);
    assertTrue(book.getClaim(address(adapter), id).exists);
    assertEq(book.getClaim(address(adapter), id).basis, 0);
    assertEq(book.getPosition(0).pendingBasis, 0);
    assertEq(book.getPosition(route).basis, oldBasis);
    assertEq(book.getPosition(route).purchases, 0);
    assertEq(book.claimTotals(0).purchases, 0);
    assertEq(book.claimTotals(0).basis, oldBasis);
    vault.refreshStrategy(route);
    vault.checkpointValuation();
    _tradeClaim(route, Side.SELL_BASE, AmountMode.EXACT_OUT);
    uint256 vaultCash = weth.balanceOf(address(vault));
    assertEq(book.claimTotals(0).basis, 0);
    queue.setFinalized(id, 1.18 ether);
    IHarborClaim(receipt).recover(1);
    vm.prank(trader);
    IHarborClaim(receipt).redeem(trader);
    assertEq(weth.balanceOf(address(vault)), vaultCash);
    vm.expectRevert();
    _claim(id);
    vm.expectRevert();
    book.recoverClaim(route, 1);
  }

  function test_LifecycleChangeInvalidatesCachedNavAndPendingQuote() public {
    (uint256 route, uint256 id, address receipt) = _externalMarket(1 ether);
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(route, Side.SELL_BASE, AmountMode.EXACT_OUT);
    assertGt(vault.maxDeposit(alice), 0);
    queue.setFinalized(id, 0.8 ether);
    assertEq(vault.maxDeposit(alice), 0);
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
    IHarborClaim(receipt).recover(1);
    assertEq(vault.maxDeposit(alice), 0);
    vault.checkpointValuation();
    (, uint256 claims,,,,) = _values();
    assertEq(claims, 0.8 ether);
    assertGt(vault.maxDeposit(alice), 0);
  }

  function test_RejectsFakeDuplicateAndUnadmittedReceiptMarkets() public {
    (uint256 route,, address receipt) = _externalMarket(1 ether);
    vm.expectRevert();
    book.registerClaimMarket(address(factory), receipt);
    vm.expectRevert();
    book.registerClaimMarket(address(factory), address(bases[0]));
    LidoClaimFactory other = new LidoClaimFactory(address(queue), address(weth), address(this));
    vm.expectRevert();
    book.registerClaimMarket(address(other), receipt);
    vm.prank(trader);
    vm.expectRevert();
    book.registerClaimMarket(address(factory), receipt);
    assertEq(book.route(route).base, receipt);
    assertEq(book.activeReceiptCount(), 0);
  }

  function _values() internal view returns (uint256 a, uint256 b, uint256 c, uint256 d, bool e, uint256 count) {
    (a, b, c, d, e) = book.valuation();
    count = book.activeReceiptCount();
  }
}
