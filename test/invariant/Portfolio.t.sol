// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/helpers/IssuerFixture.sol";
import {PortfolioHandler} from "test/invariant/PortfolioHandler.sol";
import {BookAccounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";

/// @notice Three LPs, two routes and real local settlement with independent ghosts.
contract PortfolioInvariantTest is IssuerFixture {
  PortfolioHandler private handler;
  address private charlie = address(0xc4a11e);

  function setUp() public override {
    super.setUp();
    address[3] memory actors = [alice, bob, charlie];
    for (uint256 i; i < 3; ++i) {
      weth.mint(actors[i], 100 ether);
      vm.prank(actors[i]);
      weth.approve(address(vault), type(uint256).max);
    }
    handler = new PortfolioHandler(book, vault, executor, queue, trader, actors);
    // Coverage prelude is explicit and separate from randomized-action successes.
    handler.deposit(2, 10000);
    handler.trade(0, true, true, 10000);
    handler.trade(0, true, false, 10000);
    handler.trade(0, false, true, 5000);
    handler.trade(0, false, false, 5000);
    handler.trade(1, true, true, 10000);
    handler.trade(1, false, false, 5000);
    handler.requestIssuer(5000);
    handler.recoverIssuer(0, 9000);
    handler.finishBootstrap();
    bytes4[] memory selectors = new bytes4[](10);
    selectors[0] = handler.deposit.selector;
    selectors[1] = handler.transferShares.selector;
    selectors[2] = handler.requestExit.selector;
    selectors[3] = handler.fulfill.selector;
    selectors[4] = handler.claimExit.selector;
    selectors[5] = handler.trade.selector;
    selectors[6] = handler.requestIssuer.selector;
    selectors[7] = handler.recoverIssuer.selector;
    selectors[8] = handler.donate.selector;
    selectors[9] = handler.refresh.selector;
    targetContract(address(handler));
    targetSelector(FuzzSelector(address(handler), selectors));
  }

  function prepareQuote(uint256 route, Side side, AmountMode mode, uint256 quantity)
    external
    returns (Trade memory, FillTerms memory, bytes memory, ISwapVM.Order memory)
  {
    require(msg.sender == address(handler));
    return _quote(route, side, mode, quantity);
  }

  function requestIssuer(uint256 amount) external returns (uint256 id) {
    require(msg.sender == address(handler));
    return _request(amount);
  }

  function refresh(uint256 route) external {
    require(msg.sender == address(handler));
    vault.refreshStrategy(route);
  }

  function invariant_CashNAVAndShareSupplyMatchIndependentLedger() public view {
    (uint256 cash, uint256 reserve, uint256 pending, bool valid, bool insolvent) = vault.accountingStatus();
    assertEq(cash, handler.cash());
    assertEq(reserve, handler.reserved());
    assertEq(pending, handler.pending());
    assertEq(weth.balanceOf(address(vault)), cash + handler.wethSurplus());
    assertEq(vault.totalAssets(), handler.nav());
    assertEq(vault.totalSupply(), handler.supply());
    assertEq(vault.balanceOf(address(vault)), pending);
    assertTrue(valid);
    assertFalse(insolvent);
    uint256 sum = pending;
    for (uint256 i; i < 3; ++i) {
      address actor = handler.actors(i);
      uint256 balance = handler.balances(i);
      (uint256 units, uint256 assets) = handler.credits(i);
      assertEq(vault.balanceOf(actor), balance);
      assertEq(vault.pendingRedeemRequest(0, actor), handler.pendingByActor(i));
      assertEq(vault.claimableRedeemRequest(0, actor), units);
      assertEq(vault.maxWithdraw(actor), assets);
      sum += balance;
    }
    assertEq(sum, handler.supply());
  }

  function invariant_InventoryBasisAndRightsMatchIndependentLedger() public view {
    for (uint256 i; i < 2; ++i) {
      BookAccounting.Position memory p = book.getPosition(i);
      assertEq(p.shares, handler.warehouse(i));
      assertEq(p.basis, handler.basis(i));
      assertEq(p.purchases, handler.purchases(i));
      assertEq(handler.eventGains(i), handler.gains(i));
      assertEq(p.realizedLosses, handler.losses(i));
      assertEq(p.pendingBasis, i == 0 ? handler.pendingBasis() : 0);
      assertEq(bases[i].balanceOf(address(vault)), p.shares + handler.baseSurplus(i));
    }
    for (uint256 i; i < handler.claimCount(); ++i) {
      (uint256 id, uint256 basis, uint256 remaining) = handler.claims(i);
      ClaimAccounting.Claim memory c = book.getClaim(address(adapter), id);
      assertTrue(c.exists);
      assertEq(c.basis, remaining == 0 ? 0 : basis);
      assertEq(c.remaining, remaining);
      assertEq(c.closed, remaining == 0);
    }
  }

  function afterInvariant() public view {
    for (uint256 i; i < 4; ++i) {
      assertGt(handler.modeSuccesses(i), 0);
    }
    assertGt(handler.issuerRequests(), 0);
    assertGt(handler.issuerRecoveries(), 0);
    // The deterministic prelude alone cannot make an all-no-op campaign pass.
    assertGt(handler.successes(), handler.bootstrapSuccesses());
  }
}
