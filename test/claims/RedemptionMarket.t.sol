// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedemptionMarketFixture} from "test/helpers/RedemptionMarketFixture.sol";
import {LidoClaimFactory} from "src/claims/LidoClaimFactory.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillTerms, Side, AmountMode, RedeemIntent, RouteConfig} from "src/types/HarborTypes.sol";
import {BookState} from "src/book/base/BookState.sol";
import {HarborClaimGuard} from "src/swapvm/instructions/HarborClaimGuard.sol";

contract RedemptionMarketTest is RedemptionMarketFixture {
  function test_ReceiptRouteDerivesIssuerLimitsAndKeepsIndependentPriceBounds() public {
    RouteConfig memory expected = book.route(0);
    (uint256 route,, address receipt) = _externalMarket(1 ether);
    expected.base = receipt;
    expected.adapter = address(factory);
    expected.bid = 0.97e18;
    expected.ask = 0.98e18;
    assertEq(abi.encode(book.route(route)), abi.encode(expected));
    assertEq(book.claimMarket(route).receipt, receipt);
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    uint256 basis = book.getPosition(route).basis;
    assertEq(book.getPosition(route).purchases, 0);
    assertEq(book.getPosition(route).pendingBasis, 0);
    assertEq(book.claimTotals(0).purchases, basis);
    book.retireClaimFactory(address(factory));
    assertEq(abi.encode(book.route(route)), abi.encode(expected));
    vm.expectRevert();
    book.route(route + 1);
  }

  function test_FourModesUseActualAquaReceiptAndWethTransfers() public {
    for (uint256 i; i < 2; ++i) {
      (uint256 route,, address receipt) = _externalMarket(1 ether);
      uint256 cash = weth.balanceOf(address(vault));
      _tradeClaim(route, Side.BUY_BASE, AmountMode(i));
      assertEq(IERC20(receipt).balanceOf(address(vault)), 1);
      assertEq(IERC20(receipt).balanceOf(trader), 0);
      assertLt(weth.balanceOf(address(vault)), cash);
      assertEq(book.getPosition(route).shares, 1);
      assertEq(book.activeReceiptCount(), 1);
      (uint256 inventory, uint256 claims,,,,) = _values();
      assertEq(inventory, 4 ether);
      assertEq(claims, 1.2 ether);
      _tradeClaim(route, Side.SELL_BASE, AmountMode(i));
      assertEq(IERC20(receipt).balanceOf(trader), 1);
      assertEq(book.activeReceiptCount(), 0);
      assertEq(book.getPosition(route).basis, 0);
      assertGt(weth.balanceOf(address(vault)), cash);
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

  function test_VaultRecoveryWorksAfterRetirementStopAndStaleMarks() public {
    (uint256 route, uint256 id, address receipt) = _externalMarket(1 ether);
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    book.retireClaimFactory(address(factory));
    factory.retire();
    book.stopTrading();
    valuation.setValid(false);
    uint256 cash = weth.balanceOf(address(vault));
    queue.setFinalized(id, 0.8 ether);
    vm.prank(bob);
    IHarborClaim(receipt).recover(1);
    assertEq(weth.balanceOf(address(vault)), cash);
    vm.prank(alice);
    book.recoverClaim(route, 99); // Already cash-ready: no issuer call/hint dependency.
    assertEq(weth.balanceOf(address(vault)), cash + 0.8 ether);
    assertEq(book.getPosition(route).shares, 0);
    assertEq(book.activeReceiptCount(), 0);
    assertGt(book.claimTotals(0).losses, 0);
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

  function test_PendingExitsPreventClaimPurchasesButPermitSales() public {
    (uint256 route,,) = _externalMarket(1 ether);
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    (uint256 second,,) = _externalMarket(1 ether);
    uint256 shares = vault.balanceOf(alice) / 2;
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(second, Side.BUY_BASE, AmountMode.EXACT_IN);
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
    _tradeClaim(route, Side.SELL_BASE, AmountMode.EXACT_IN);
    vault.fulfillWithdrawals(1);
    assertGt(vault.maxWithdraw(alice), 0);
  }

  function test_FactoryRequiresSeparateDelayedAdmission() public {
    LidoClaimFactory other = new LidoClaimFactory(address(queue), address(weth), address(this));
    vm.expectRevert();
    book.activateClaimFactory(address(other));
    book.scheduleClaimFactory(address(other), 0, 0.97e18, 0.98e18);
    vm.expectRevert();
    book.activateClaimFactory(address(other));
    vm.prank(trader);
    vm.expectRevert();
    book.retireClaimFactory(address(factory));
    book.retireClaimFactory(address(other));
    vm.warp(block.timestamp + 1 days);
    vm.expectRevert();
    book.activateClaimFactory(address(other));
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

  function test_AdmissionRejectsForeignIssuerAndReceiptAsParent() public {
    LidoClaimFactory foreign = new LidoClaimFactory(address(bases[0]), address(weth), address(this));
    vm.expectRevert();
    book.scheduleClaimFactory(address(foreign), 0, 0.97e18, 0.98e18);
    (uint256 route,,) = _externalMarket(1 ether);
    LidoClaimFactory other = new LidoClaimFactory(address(queue), address(weth), address(this));
    vm.expectRevert();
    book.scheduleClaimFactory(address(other), route, 0.97e18, 0.98e18);
  }

  function test_RetirementCancelsOldQuotesAndNewSalesReleaseExposure() public {
    (uint256 route,,) = _externalMarket(1 ether);
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(route, Side.SELL_BASE, AmountMode.EXACT_IN);
    factory.retire();
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
    vault.refreshStrategy(route);
    _tradeClaim(route, Side.SELL_BASE, AmountMode.EXACT_IN);
    (t, f, sig, order) = _claimQuote(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
  }

  function test_RevokedApprovalRollsBackNonceAndPosition() public {
    (uint256 route,, address receipt) = _externalMarket(1 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    vm.prank(trader);
    IERC20(receipt).approve(address(executor), 0);
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
    assertFalse(book.usedQuoteNonce(f.epoch, f.nonce));
    assertEq(book.getPosition(route).shares, 0);
    assertEq(IERC20(receipt).balanceOf(trader), 1);
  }

  function test_ZeroRecoveryClosesAndNeverSpendsLpReserves() public {
    (uint256 route, uint256 id,) = _externalMarket(1 ether);
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    uint256 shares = vault.balanceOf(alice) / 2;
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    vault.fulfillWithdrawals(1);
    uint256 reserved = vault.maxWithdraw(alice);
    uint256 cash = weth.balanceOf(address(vault));
    queue.setFinalized(id, 0);
    book.recoverClaim(route, 1);
    assertEq(weth.balanceOf(address(vault)), cash);
    assertEq(vault.maxWithdraw(alice), reserved);
    assertEq(book.activeReceiptCount(), 0);
  }

  function _values() internal view returns (uint256 a, uint256 b, uint256 c, uint256 d, bool e, uint256 count) {
    (a, b, c, d, e) = book.valuation();
    count = book.activeReceiptCount();
  }

  function test_LateFeeFailureRollsBackClaimBookAndAqua() public {
    (uint256 route,, address receipt) = _externalMarket(1 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    uint256 beforeCash = weth.balanceOf(address(vault));
    (uint256 beforeAllocation,) =
      aqua.safeBalances(address(vault), address(router), f.orderHash, address(weth), receipt);
    vm.mockCallRevert(address(weth), abi.encodeCall(IERC20.transfer, (feeRecipient, f.fee)), "fee rejected");
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
    assertEq(weth.balanceOf(address(vault)), beforeCash);
    assertEq(IERC20(receipt).balanceOf(trader), 1);
    assertEq(book.activeReceiptCount(), 0);
    assertEq(book.claimTotals(0).purchases, 0);
    assertFalse(book.usedQuoteNonce(f.epoch, f.nonce));
    assertFalse(book.usedTraderNonce(trader, t.nonce));
    (uint256 afterAllocation,) = aqua.safeBalances(address(vault), address(router), f.orderHash, address(weth), receipt);
    assertEq(beforeAllocation, afterAllocation);
    vm.clearMockedCalls();
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertEq(book.activeReceiptCount(), 1);
  }

  function test_ClaimTermsRequireIndependentPermitAndRejectSubstitution() public {
    (uint256 route,,) = _externalMarket(1 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    bytes32 digest = executor.fillDigest(t, f);
    _setApproval(digest, false);
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
    _setApproval(digest, true);
    t.receiver = bob;
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
    t.receiver = trader;
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
  }

  function test_ExportFailurePreservesNativeCustodyAndBasis() public {
    uint256 id = _request(1 ether);
    uint256 basis = book.getPosition(0).pendingBasis;
    factory.retire();
    vm.expectRevert();
    book.exportClaim(0, id, address(factory));
    assertEq(queue.ownerOf(id), address(adapter));
    assertFalse(adapter.closed(id));
    assertFalse(book.getClaim(address(adapter), id).closed);
    assertEq(book.getPosition(0).pendingBasis, basis);
    assertEq(book.activeReceiptCount(), 0);
  }

  function test_NativeAndReceiptPositionsShareSixtyFourPositionCap() public {
    uint256 nativeId = _request(0.001 ether);
    vault.checkpointValuation();
    for (uint256 i; i < 63; ++i) {
      (uint256 route,,) = _externalMarket(0.001 ether);
      _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    }
    assertEq(book.activeReceiptCount(), 63);
    (uint256 extra,,) = _externalMarket(0.001 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(extra, Side.BUY_BASE, AmountMode.EXACT_IN);
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(t, f, sig, order);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 0.001 ether;
    RedeemIntent memory intent = _intent(amounts);
    vm.expectRevert();
    book.requestRedemption(intent, amounts);
    // Export replaces one native right; it must not require a 65th position.
    book.exportClaim(0, nativeId, address(factory));
    assertEq(book.activeReceiptCount(), 64);
  }
}
