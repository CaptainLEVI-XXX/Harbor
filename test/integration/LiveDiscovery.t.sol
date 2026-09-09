// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedemptionMarketFixture} from "test/claims/RedemptionMarket.t.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {Side, AmountMode} from "src/types/HarborTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Live discovery requires no historical database, mark provider or issuer observation.
contract LiveDiscoveryTest is RedemptionMarketFixture {
  function test_EmptyPagesAndInvalidBounds() public {
    (BookPortfolio.NativeClaim[] memory claims, uint256 next) = book.activeNativeClaims(0, 32);
    assertEq(claims.length, 0);
    assertEq(next, 0);
    (uint256[] memory routes, uint256 receiptNext) = book.activeReceiptRoutes(0, 32);
    assertEq(routes.length, 0);
    assertEq(receiptNext, 0);
    vm.expectRevert(BookPortfolio.InvalidPage.selector);
    book.activeNativeClaims(0, 0);
    vm.expectRevert(BookPortfolio.InvalidPage.selector);
    book.activeNativeClaims(0, 33);
    vm.expectRevert(BookPortfolio.InvalidPage.selector);
    book.activeNativeClaims(type(uint256).max, 1);
    vm.expectRevert(ClaimMarkets.InvalidPage.selector);
    book.activeReceiptRoutes(0, 0);
    vm.expectRevert(ClaimMarkets.InvalidPage.selector);
    book.activeReceiptRoutes(0, 33);
    vm.expectRevert(ClaimMarkets.InvalidPage.selector);
    book.activeReceiptRoutes(type(uint256).max, 1);
  }

  function test_NativeSwapPopExportAndRecoveryCanBeDiscoveredWithoutMarks() public {
    uint256 first = _request(0.5 ether);
    uint256 middle = _request(0.5 ether);
    uint256 last = _request(0.5 ether);
    (BookPortfolio.NativeClaim[] memory claims, uint256 next) = book.activeNativeClaims(0, 2);
    assertEq(next, 2);
    assertEq(claims.length, 2);
    assertEq(claims[0].issuerId, first);
    assertEq(claims[0].adapter, address(adapter));
    assertEq(claims[0].route, 0);
    assertEq(claims[0].key, ClaimAccounting.key(address(adapter), first));
    assertEq(claims[0].basis, 0.495 ether);
    assertEq(claims[0].remaining, 0.6 ether);
    assertEq(claims[0].received, 0);
    (claims, next) = book.activeNativeClaims(next, 2);
    assertEq(next, 3);
    assertEq(claims.length, 1);
    assertEq(claims[0].issuerId, last);

    queue.setFinalized(middle, 0);
    _claim(middle);
    (claims,) = book.activeNativeClaims(0, 32);
    assertEq(claims.length, 2);
    assertEq(claims[0].issuerId, first);
    assertEq(claims[1].issuerId, last);

    uint256 route = book.exportClaim(0, first, address(factory));
    (uint256[] memory routes,) = book.activeReceiptRoutes(0, 32);
    assertEq(routes.length, 1);
    assertEq(routes[0], route);
    assertEq(book.claimMarket(routes[0]).requestId, first);
    assertEq(book.claimMarket(routes[0]).receipt, book.route(route).base);
    assertTrue(book.getClaim(address(adapter), first).closed);

    book.stopTrading();
    valuation.setValid(false);
    (claims,) = book.activeNativeClaims(0, 32);
    assertEq(claims.length, 1);
    assertEq(claims[0].issuerId, last);
    queue.setFinalized(claims[0].issuerId, 0.5 ether);
    _claim(claims[0].issuerId);
    queue.setFinalized(first, 0.5 ether);
    book.recoverClaim(routes[0], 1);
    (claims,) = book.activeNativeClaims(0, 32);
    (routes,) = book.activeReceiptRoutes(0, 32);
    assertEq(claims.length, 0);
    assertEq(routes.length, 0);
  }

  function test_ReceiptSwapPopAndReacquisitionExposeOnlyLiveRoutes() public {
    (uint256 first,, address receipt) = _externalMarket(1 ether);
    (uint256 second,,) = _externalMarket(1 ether);
    _tradeClaim(first, Side.BUY_BASE, AmountMode.EXACT_IN);
    _tradeClaim(second, Side.BUY_BASE, AmountMode.EXACT_OUT);
    (uint256[] memory routes, uint256 next) = book.activeReceiptRoutes(0, 1);
    assertEq(routes[0], first);
    (routes, next) = book.activeReceiptRoutes(next, 1);
    assertEq(routes[0], second);
    assertEq(next, 2);
    _tradeClaim(first, Side.SELL_BASE, AmountMode.EXACT_IN);
    (routes,) = book.activeReceiptRoutes(0, 32);
    assertEq(routes.length, 1);
    assertEq(routes[0], second);
    vm.prank(trader);
    IERC20(receipt).approve(address(executor), 1);
    _tradeClaim(first, Side.BUY_BASE, AmountMode.EXACT_OUT);
    (routes,) = book.activeReceiptRoutes(0, 32);
    assertEq(routes.length, 2);
    assertEq(routes[0], second);
    assertEq(routes[1], first);
  }

  function testFuzz_NativePageReturnsExactSlice(uint256 cursorSeed, uint256 limitSeed) public {
    for (uint256 i; i < 5; ++i) {
      _request(0.1 ether);
    }
    uint256 cursor = bound(cursorSeed, 0, 5);
    uint256 limit = bound(limitSeed, 1, 32);
    (BookPortfolio.NativeClaim[] memory all,) = book.activeNativeClaims(0, 32);
    (BookPortfolio.NativeClaim[] memory page, uint256 next) = book.activeNativeClaims(cursor, limit);
    uint256 size = 5 - cursor;
    if (size > limit) size = limit;
    assertEq(page.length, size);
    assertEq(next, cursor + size);
    for (uint256 i; i < size; ++i) {
      assertEq(abi.encode(page[i]), abi.encode(all[cursor + i]));
    }
  }
}
