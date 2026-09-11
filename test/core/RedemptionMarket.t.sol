// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedemptionMarketFixture} from "test/base/RedemptionMarketFixture.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {HarborClaimReceipt} from "src/claims/HarborClaimReceipt.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {Vm} from "forge-std/Vm.sol";
import {BookState} from "src/book/base/BookState.sol";
import {HarborClaimGuard} from "src/swapvm/instructions/HarborClaimGuard.sol";
import {AdapterBase} from "src/adapters/base/AdapterBase.sol";
import {ClaimImport, CollateralKind} from "src/types/ClaimTypes.sol";
import {ClaimObservation} from "src/types/ClaimTypes.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {LidoViews} from "src/adapters/lido/LidoViews.sol";
import {MockLidoQueue} from "test/base/LidoFixture.sol";

contract RedemptionMarketTest is RedemptionMarketFixture {
  address private recoveringReceipt;
  uint256 private rejectedTransfer;

  // Queue callback probes a genuinely approved transfer during direct adapter recovery.
  function reenter() external {
    require(msg.sender == address(queue));
    (bool ok,) = recoveringReceipt.call(abi.encodeCall(IERC20.transferFrom, (trader, bob, 1)));
    assertFalse(ok);
    ++rejectedTransfer;
  }

  function test_FourModesUseActualAquaReceiptAndWethTransfers() public {
    for (uint256 i; i < 2; ++i) {
      (uint256 route,, address receipt) = _externalMarket(1 ether);
      uint256 cash = weth.balanceOf(address(vault));
      _assertReceiptObservation(route, receipt);
      _measuredClaimTrade(route, Side.BUY_BASE, AmountMode(i));
      assertEq(IERC20(receipt).balanceOf(address(vault)), 1);
      assertEq(IERC20(receipt).balanceOf(trader), 0);
      assertEq(weth.balanceOf(address(vault)), cash - 1.164 ether);
      assertEq(book.getPosition(route).shares, 1);
      assertEq(book.activeReceiptCount(), 1);
      (uint256 inventory, uint256 claims,,,,) = _values();
      assertEq(inventory, 4.8 ether);
      assertEq(claims, 1.2 ether);
      _measuredClaimTrade(route, Side.SELL_BASE, AmountMode(i));
      assertEq(IERC20(receipt).balanceOf(trader), 1);
      assertEq(book.activeReceiptCount(), 0);
      assertEq(book.getPosition(route).basis, 0);
      assertEq(weth.balanceOf(address(vault)), cash + 0.012 ether);
      assertEq(IERC20(receipt).balanceOf(address(executor)), 0);
      assertEq(IERC20(receipt).balanceOf(address(router)), 0);
      assertEq(IERC20(receipt).allowance(address(executor), address(router)), 0);
    }
    _measureReceiptLifecycle();
  }

  /// @dev Identical issuer setup across clone variants. Timers exclude request,
  /// approval, synthetic finalization and assertions; report each operation alone.
  function _measureReceiptLifecycle() private {
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1 ether;
    vm.startPrank(trader);
    bases[0].approve(address(queue), amounts[0]);
    uint256 id = queue.requestWithdrawalsWstETH(amounts, trader)[0];
    queue.approve(address(adapter), id);
    ClaimImport memory input = ClaimImport(CollateralKind.ERC721, address(queue), id, 1, "");
    uint256 start = gasleft();
    address receipt = factory.wrap(address(adapter), input, trader);
    uint256 wrapping = start - gasleft();
    vm.stopPrank();
    assertEq(IHarborClaim(receipt).ADAPTER(), address(adapter));
    assertEq(IHarborClaim(receipt).CLAIM_ID(), adapter.nativeClaimId(id));
    assertEq(IERC20(receipt).balanceOf(trader), 1);
    queue.setFinalized(id, 1.18 ether);
    start = gasleft();
    uint256 cash = IHarborClaim(receipt).recover(abi.encode(uint256(1)));
    uint256 recovery = start - gasleft();
    assertEq(cash, 1.18 ether);
    uint256 beforeCash = weth.balanceOf(trader);
    vm.prank(trader);
    start = gasleft();
    cash = IHarborClaim(receipt).redeem(trader);
    uint256 redemption = start - gasleft();
    assertEq(cash, 1.18 ether);
    assertEq(weth.balanceOf(trader), beforeCash + cash);
    assertEq(IERC20(receipt).totalSupply(), 0);
    emit log_named_uint("receipt wrap gas", wrapping);
    emit log_named_uint("receipt recover gas", recovery);
    emit log_named_uint("receipt redeem gas", redemption);
    emit log_named_uint("receipt clone runtime bytes", receipt.code.length);
  }

  /// @dev Compare every returned word and the evidence preimage with direct issuer-backed data.
  function _assertReceiptObservation(uint256 route, address receipt) private {
    bytes32 id = IHarborClaim(receipt).CLAIM_ID();
    ClaimObservation memory o = adapter.claimState(id);
    bytes32 expectedHash = keccak256(
      abi.encode(address(factory), receipt, address(adapter), id, o.entitlement, o.mark, o.observedAt, uint256(1))
    );
    vm.startStateDiffRecording();
    uint256 beforeGas = gasleft();
    (uint256 face, uint256 mark, uint256 time, uint256 policy, bytes32 evidence, bool valid) =
      book.observation(route, 1);
    emit log_named_uint("receipt observation gas", beforeGas - gasleft());
    uint256 calls = _statusCalls(vm.stopAndReturnStateDiff());
    emit log_named_uint("receipt observation issuer reads", calls);
    assertEq(calls, o.status == IHarborClaim.Status.PENDING || o.status == IHarborClaim.Status.FINALIZED ? 1 : 0);
    assertEq(
      abi.encode(face, mark, time, policy, evidence, valid),
      abi.encode(o.entitlement, o.mark, o.observedAt, uint256(1), expectedHash, o.valid)
    );
  }

  /// @dev Warm execution only, excluding previews, approvals, checkpoint and assertions.
  function _measuredClaimTrade(uint256 route, Side side, AmountMode mode) private {
    (Trade memory t, FillAmounts memory expected) = _claimQuote(route, side, mode);
    assertEq(abi.encode(executor.quote(address(book), t)), abi.encode(expected));
    _assertRouterQuote(t, expected);
    vm.startStateDiffRecording();
    vm.prank(trader);
    uint256 beforeGas = gasleft();
    (uint256 input, uint256 output) = executor.execute(address(book), t);
    uint256 used = beforeGas - gasleft();
    uint256 calls = _statusCalls(vm.stopAndReturnStateDiff());
    emit log_named_uint(side == Side.BUY_BASE ? "receipt buy gas" : "receipt sell gas", used);
    emit log_named_uint("receipt trade issuer reads", calls);
    // The sold receipt also participates in the pre-trade portfolio batch.
    // The VM now enters the Book's own check; the extra private guard opcode is
    // gone. Live observation and final post-callback custody checks remain.
    assertEq(calls, side == Side.BUY_BASE ? 4 : 5);
    assertEq(input, expected.traderIn);
    assertEq(output, expected.traderOut);
    vault.checkpointValuation();
  }

  function _statusCalls(Vm.AccountAccess[] memory accesses) private view returns (uint256 calls) {
    for (uint256 i; i < accesses.length; ++i) {
      if (
        accesses[i].account == address(queue)
          && bytes4(accesses[i].data) == bytes4(keccak256("getWithdrawalStatus(uint256[])"))
      ) ++calls;
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
    _configureReceipt(route);
    vault.checkpointValuation();
    _tradeClaim(route, Side.SELL_BASE, AmountMode.EXACT_OUT);
    uint256 vaultCash = weth.balanceOf(address(vault));
    uint256 holderCash = weth.balanceOf(trader);
    uint256 expectedRecovery = 1.18 ether;
    IHarborClaim claim = IHarborClaim(receipt);
    assertEq(book.claimTotals(0).basis, 0);
    assertEq(IERC20(receipt).balanceOf(trader), 1);
    assertEq(IERC20(receipt).totalSupply(), 1);
    queue.setFinalized(id, expectedRecovery);
    assertEq(uint256(claim.status()), uint256(IHarborClaim.Status.FINALIZED));
    // Permissionless recovery funds escrow, not the caller or the previous seller.
    assertEq(claim.recover(abi.encode(uint256(1))), expectedRecovery);
    assertEq(uint256(claim.status()), uint256(IHarborClaim.Status.CASH_READY));
    assertEq(claim.recovered(), expectedRecovery);
    assertEq(weth.balanceOf(address(adapter)), expectedRecovery);
    assertEq(adapter.totalClaimCash(), expectedRecovery);
    assertEq(weth.balanceOf(trader), holderCash);
    vm.expectRevert(HarborClaimReceipt.InvalidState.selector);
    vm.prank(bob);
    claim.redeem(bob);
    // A failed token payment must restore both the unit and its adapter credit.
    vm.mockCallRevert(address(weth), abi.encodeCall(IERC20.transfer, (trader, expectedRecovery)), hex"deadbeef");
    vm.expectRevert();
    vm.prank(trader);
    claim.redeem(trader);
    vm.clearMockedCalls();
    assertEq(IERC20(receipt).balanceOf(trader), 1);
    assertEq(claim.recovered(), expectedRecovery);
    assertEq(adapter.totalClaimCash(), expectedRecovery);
    vm.prank(trader);
    assertEq(claim.redeem(trader), expectedRecovery);
    assertEq(weth.balanceOf(trader), holderCash + expectedRecovery);
    assertEq(weth.balanceOf(address(adapter)), 0);
    assertEq(IERC20(receipt).balanceOf(trader), 0);
    assertEq(IERC20(receipt).totalSupply(), 0);
    assertEq(claim.recovered(), 0);
    assertEq(adapter.totalClaimCash(), 0);
    assertEq(uint256(claim.status()), uint256(IHarborClaim.Status.CLOSED));
    vm.expectRevert(HarborClaimReceipt.InvalidState.selector);
    vm.prank(trader);
    claim.redeem(trader);
    assertEq(weth.balanceOf(trader), holderCash + expectedRecovery);
    assertEq(weth.balanceOf(address(vault)), vaultCash);
    assertEq(factory.receiptOf(address(adapter), claim.CLAIM_ID()), receipt);
    vm.expectRevert();
    vm.prank(trader);
    factory.wrap(address(adapter), ClaimImport(CollateralKind.ERC721, address(queue), id, 1, ""), trader);
    vm.expectRevert();
    _claim(id);
    vm.expectRevert();
    book.recoverClaim(route, abi.encode(uint256(1)));
    _isolatedCashAndIssuerOutage();
  }

  function _isolatedCashAndIssuerOutage() private {
    (, uint256 firstId, address first) = _externalMarket(1 ether);
    (, uint256 secondId, address second) = _externalMarket(2 ether);
    queue.setFinalized(firstId, 0.8 ether);
    recoveringReceipt = first;
    vm.prank(trader);
    IERC20(first).approve(address(this), 1);
    queue.setCallback(address(this));
    adapter.recoverTokenized(IHarborClaim(first).CLAIM_ID(), abi.encode(uint256(1)));
    queue.setCallback(address(0));
    assertEq(rejectedTransfer, 1);
    assertEq(IERC20(first).balanceOf(trader), 1);
    // Claim A's recovered cash must not make pending claim B redeemable.
    vm.expectRevert();
    vm.prank(trader);
    IHarborClaim(second).redeem(trader);
    bytes32[] memory ids = new bytes32[](2);
    ids[0] = IHarborClaim(first).CLAIM_ID();
    ids[1] = IHarborClaim(second).CLAIM_ID();
    (, ClaimObservation[] memory observed) = adapter.observePortfolio(address(bases[0]), 0, ids);
    assertEq(observed[0].cash, 0.8 ether);
    assertEq(observed[1].mark, 2.4 ether);
    ids[1] = ids[0];
    vm.expectRevert();
    adapter.observePortfolio(address(bases[0]), 0, ids);
    vm.expectRevert();
    adapter.observePortfolio(address(bases[0]), 0, new bytes32[](65));
    queue.setFinalized(secondId, 1.7 ether);
    IHarborClaim(second).recover(abi.encode(uint256(1)));
    assertEq(adapter.totalClaimCash(), 2.5 ether);
    // Even the smaller claim must stop when aggregate backing is deficient.
    weth.burn(address(adapter), 1);
    vm.expectRevert(AdapterBase.ReceiptMismatch.selector);
    vm.prank(trader);
    IHarborClaim(first).redeem(trader);
    assertEq(IERC20(first).balanceOf(trader), 1);
    assertEq(adapter.totalClaimCash(), 2.5 ether);
    weth.mint(address(adapter), 1);
    factory.retire(address(adapter));
    adapter.revokePublisher();
    vm.mockCallRevert(address(queue), abi.encodeWithSignature("getWithdrawalStatus(uint256[])"), hex"deadbeef");
    uint256 beforeCash = weth.balanceOf(trader);
    vm.startPrank(trader);
    assertEq(IHarborClaim(first).redeem(trader), 0.8 ether);
    assertEq(IHarborClaim(second).redeem(trader), 1.7 ether);
    vm.stopPrank();
    assertEq(weth.balanceOf(trader), beforeCash + 2.5 ether);
    assertEq(adapter.totalClaimCash(), 0);
    assertEq(weth.balanceOf(address(adapter)), 0);
    assertEq(uint256(IHarborClaim(first).status()), uint256(IHarborClaim.Status.CLOSED));
    vm.clearMockedCalls();
  }

  function test_LifecycleChangeInvalidatesCachedNavAndPendingQuote() public {
    (uint256 route, uint256 id, address receipt) = _externalMarket(1 ether);
    _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
    (Trade memory t,) = _claimQuote(route, Side.SELL_BASE, AmountMode.EXACT_OUT);
    assertGt(vault.maxDeposit(alice), 0);
    queue.setFinalized(id, 0.8 ether);
    _assertReceiptObservation(route, receipt);
    assertEq(vault.maxDeposit(alice), 0);
    vm.prank(trader);
    vm.expectRevert();
    executor.execute(address(book), t);
    IHarborClaim(receipt).recover(abi.encode(uint256(1)));
    _assertReceiptObservation(route, receipt);
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
    HarborClaimFactory other = new HarborClaimFactory(address(weth), address(this), 1 days);
    vm.expectRevert();
    book.registerClaimMarket(address(other), receipt);
    vm.prank(trader);
    vm.expectRevert();
    book.registerClaimMarket(address(factory), receipt);
    assertEq(book.route(route).base, receipt);
    assertEq(book.activeReceiptCount(), 0);
    // Registered FACE is immutable; a later adapter observation cannot redefine it.
    bytes32 claimId = IHarborClaim(receipt).CLAIM_ID();
    ClaimObservation memory changed = adapter.claimState(claimId);
    ++changed.entitlement;
    vm.mockCall(address(adapter), abi.encodeCall(LidoViews.claimState, (claimId)), abi.encode(changed));
    (,,,,, bool valid) = book.observation(route, 1);
    assertFalse(valid);
    vm.clearMockedCalls();
    // Sharing a factory does not approve a second custody adapter for this pool.
    MockLidoQueue secondQueue = new MockLidoQueue(address(bases[0]));
    LidoAdapter second = new LidoAdapter(
      address(book),
      address(vault),
      address(bases[0]),
      address(weth),
      address(secondQueue),
      LidoViews.Config(address(factory), address(this), address(this), 60, 1 days)
    );
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1 ether;
    vm.startPrank(trader);
    bases[0].approve(address(secondQueue), amounts[0]);
    uint256 id = secondQueue.requestWithdrawalsWstETH(amounts, trader)[0];
    secondQueue.approve(address(second), id);
    ClaimImport memory input = ClaimImport(CollateralKind.ERC721, address(secondQueue), id, 1, "");
    vm.expectRevert();
    factory.wrap(address(second), input, trader);
    vm.stopPrank();
    factory.schedule(address(second));
    vm.warp(vm.getBlockTimestamp() + 1 days);
    factory.activate(address(second));
    vm.prank(trader);
    address otherReceipt = factory.wrap(address(second), input, trader);
    assertTrue(factory.isReceipt(otherReceipt));
    assertNotEq(second.nativeClaimId(id), adapter.nativeClaimId(id));
    assertNotEq(otherReceipt, receipt);
    vm.expectRevert();
    book.registerClaimMarket(address(factory), otherReceipt);
    assertFalse(book.claimIntegration(address(factory), address(second)).enabled);
  }

  function _values() internal view returns (uint256 a, uint256 b, uint256 c, bytes32 d, bool e, uint256 count) {
    (a, b, c, d, e) = book.valuation();
    count = book.activeReceiptCount();
  }
}
