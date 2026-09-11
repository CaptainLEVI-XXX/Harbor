// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/base/IssuerFixture.sol";
import {MockLidoQueue} from "test/base/LidoFixture.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {BookState} from "src/book/base/BookState.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {LidoViews} from "src/adapters/lido/LidoViews.sol";
import {RouteConfig, Trade, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingParameters} from "src/types/PricingTypes.sol";

/// @notice Targeted chain-boundary checks, invoked from the retained publication test.
contract HoodiDemoChecks is IssuerFixture {
  function check() external {
    vm.chainId(560048);
    setUp();
    uint256 time = vm.getBlockTimestamp();
    vm.prank(trader);
    vm.expectRevert(HarborClaimFactory.Unauthorized.selector);
    factory.schedule(address(adapter));
    factory.schedule(address(adapter));
    factory.activate(address(adapter)); // No warp: explicit, authenticated admission.
    book.scheduleClaimFactory(address(factory), 0, 0.97e18, 0.98e18);
    vm.prank(trader);
    vm.expectRevert(BookState.Unauthorized.selector);
    book.activateClaimFactory(address(factory), address(adapter));
    book.activateClaimFactory(address(factory), address(adapter));
    assertEq(vm.getBlockTimestamp(), time);
    assertTrue(book.claimIntegration(address(factory), address(adapter)).enabled);
    vm.expectRevert();
    book.activateClaimFactory(address(factory), address(adapter));
    // Independent marks and prices both accept exactly 100 days.
    adapter.publish(1e18, 1e18, time, time + 100 days, adapter.version() + 1);
    PricingParameters memory p =
      PricingParameters(1e18, time, time + 100 days, book.pricingParameters(0).version + 1, book.configVersion());
    book.publishPricing(0, p);
    ++p.version;
    ++p.validUntil;
    vm.expectRevert();
    book.publishPricing(0, p);
    uint256 next = adapter.version() + 1;
    vm.expectRevert();
    adapter.publish(1e18, 1e18, time, time + 100 days + 1, next);
    Trade memory t = _trade(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether, 0);
    t.deadline = time + 100 days + 1;
    vm.warp(time + 100 days);
    assertGt(executor.quote(address(book), t).traderOut, 0);
    vm.warp(time + 100 days + 1);
    vm.expectRevert();
    executor.quote(address(book), t);
    // The unrelated governor delay is still enforced on Hoodi.
    book.scheduleUpdater(trader);
    vm.expectRevert(BookState.Unauthorized.selector);
    book.applyUpdater();
    // The exception must not silently broaden other networks' constructor limits.
    vm.chainId(1);
    RouteConfig[] memory routes = new RouteConfig[](1);
    routes[0] = book.route(0);
    HarborBook.Config memory c = deploymentConfig;
    c.maxParameterAge = 100 days;
    vm.expectRevert(BookState.InvalidConfiguration.selector);
    new HarborBook(c, routes);
    vm.expectRevert(HarborClaimFactory.InvalidConfiguration.selector);
    new HarborClaimFactory(address(weth), address(this), 0);
    vm.expectRevert();
    new LidoAdapter(
      address(book),
      address(vault),
      address(bases[0]),
      address(weth),
      address(queue),
      LidoViews.Config(address(factory), address(this), address(this), 100 days, 1 days)
    );
  }

  function _nativeRoutes() internal pure override returns (uint256) {
    return 1;
  }

  function _deployBook(HarborBook.Config memory c, RouteConfig[] memory routes) internal override returns (HarborBook) {
    c.maxParameterAge = c.maxMarkAge = 100 days;
    c.feeBps = 0;
    return new HarborBook(c, routes);
  }

  function _afterDeploy() internal override {
    queue = new MockLidoQueue(address(bases[0]));
    adapter = new LidoAdapter(
      address(book),
      address(vault),
      address(bases[0]),
      address(weth),
      address(queue),
      LidoViews.Config(address(factory), address(this), address(this), 100 days, 1 days)
    );
    assertEq(book.route(0).adapter, address(adapter));
    valuation.setConversion(address(bases[0]), 1.2e18, 1e18);
    _refreshMarks();
    vm.deal(address(queue), 100 ether);
  }
}
