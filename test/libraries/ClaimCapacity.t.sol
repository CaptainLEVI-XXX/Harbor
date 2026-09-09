// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {BookAccounting} from "src/libraries/BookAccounting.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";

/// @notice Explicit synthetic ledger setup isolates shared budget arithmetic from settlement.
contract ClaimCapacityHarness {
  BookAccounting.State internal book;
  ClaimMarkets.State internal markets;
  RouteConfig[] internal routes;

  constructor() {
    TokenMock token = new TokenMock("Units", "UNIT");
    token.mint(address(this), 100);
    for (uint256 i; i < 2; ++i) {
      routes.push(RouteConfig(address(token), address(1), 1e18, 1e18, 0, 0, 100, 200, 5, 100));
    }
    markets.markets[2] = ClaimMarkets.Market(address(2), address(token), 0, 1);
    book.positions[0] = BookAccounting.Position(10, 60, 10, 80, 1, 0);
    book.positions[1] = BookAccounting.Position(10, 10, 0, 10, 0, 0);
  }

  function totals(uint256 basis, uint256 purchases, uint256 losses) external {
    markets.totals[0] = ClaimMarkets.Totals(basis, purchases, losses);
  }

  function hold(uint256 basis) external {
    book.positions[2].shares = 1;
    book.positions[2].basis = basis;
  }

  function check(uint256 route, bool buy, uint256 cash, uint256 maxExposure) external view {
    BookPortfolio.capacity(book, markets, routes, 2, route, buy, 1, cash, 100, maxExposure, address(this));
  }
}

contract ClaimCapacityTest is Test {
  ClaimCapacityHarness internal h = new ClaimCapacityHarness();

  function test_ReceiptAndNativePurchasesShareIssuerExposure() public {
    h.totals(25, 100, 3);
    h.check(2, true, 5, 200);
    vm.expectRevert(BookPortfolio.CapacityExceeded.selector);
    h.check(2, true, 6, 200);
    vm.expectRevert(BookPortfolio.CapacityExceeded.selector);
    h.check(0, true, 6, 200);
    h.check(1, true, 6, 200);
  }

  function test_ReceiptLossesAndPurchasesCannotResetOnNewRoute() public {
    h.totals(0, 120, 0);
    vm.expectRevert(BookPortfolio.CapacityExceeded.selector);
    h.check(2, true, 1, 200);
    vm.expectRevert(BookPortfolio.CapacityExceeded.selector);
    h.check(0, true, 1, 200);
    h.totals(0, 0, 4);
    vm.expectRevert(BookPortfolio.CapacityExceeded.selector);
    h.check(2, true, 1, 200);
    h.check(1, true, 1, 200);
  }

  function test_SaleLossAndAggregateLimitsIncludeOtherPositions() public {
    h.totals(10, 0, 3);
    h.hold(10);
    h.check(2, false, 9, 200);
    vm.expectRevert(BookPortfolio.CapacityExceeded.selector);
    h.check(2, false, 8, 200);
    vm.expectRevert(BookPortfolio.CapacityExceeded.selector);
    h.check(1, true, 11, 100);
    h.check(1, true, 10, 100);
  }
}
