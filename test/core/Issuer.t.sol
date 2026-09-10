// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {VaultState} from "src/vault/base/VaultState.sol";
import {IssuerFixture} from "test/base/IssuerFixture.sol";
import {BookAccounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {RedemptionAccounting} from "src/libraries/RedemptionAccounting.sol";
import {BookState} from "src/book/base/BookState.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {RedeemIntent} from "src/types/HarborTypes.sol";
import {RealizationLogs} from "test/base/RealizationLogs.sol";
import {LidoFixture} from "test/base/LidoFixture.sol";
import {AdapterBase} from "src/adapters/base/AdapterBase.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {LidoValuation} from "src/valuation/LidoValuation.sol";
import {NativeValuationFixture} from "test/base/NativeValuationFixture.sol";

contract IssuerRecoveryTest is NativeValuationFixture {
  function test_RecoveryFundsPendingFIFOExitsUsingActualWETH() public {
    _buy(0, 16 ether);
    assertEq(book.faceExposure(), 19.2 ether);
    uint256 id = _request(16 ether);
    assertEq(book.faceExposure(), 19.2 ether);
    vault.checkpointValuation();
    uint256 shares = vault.balanceOf(alice);
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    vault.fulfillWithdrawals(1);
    assertGt(vault.pendingRedeemRequest(0, alice), 0);
    assertEq(vault.maxWithdraw(alice), 0.992 ether);
    queue.setFinalized(id, 19.2 ether);
    book.revokeUpdater();
    LidoValuation(address(valuation)).revokePublisher();
    assertEq(vault.maxWithdraw(alice), 0.992 ether); // Funded credit survives both outages.
    _claim(id);
    assertEq(book.faceExposure(), 0);
    vault.checkpointValuation();
    vault.fulfillWithdrawals(1);
    assertEq(vault.pendingRedeemRequest(0, alice), 0);
    uint256 credit = vault.maxWithdraw(alice);
    assertGt(credit, 10 ether);
    uint256 beforeBalance = weth.balanceOf(alice);
    vm.prank(alice);
    vault.withdraw(credit, alice, alice);
    assertEq(weth.balanceOf(alice), beforeBalance + credit);
  }

  function test_KeeperIntentDomainReplayAndExactInventoryAreEnforced() public {
    _buy(0, 2 ether);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1 ether;
    RedeemIntent memory intent = _intent(amounts);
    vm.prank(alice);
    vm.expectRevert(BookState.Unauthorized.selector);
    book.requestRedemption(intent, amounts);
    intent.chainId += 1;
    vm.expectRevert(RedemptionAccounting.InvalidIntent.selector);
    book.requestRedemption(intent, amounts);
    intent.chainId = block.chainid;
    intent.minUnderlying += 1;
    vm.expectRevert(RedemptionAccounting.InvalidIntent.selector);
    book.requestRedemption(intent, amounts);
    assertFalse(book.usedRedemptionNonce(intent.epoch, intent.nonce));
    assertEq(book.redemptionUsedToday(0), 0);
    assertEq(queue.nextId(), 0);
    assertEq(bases[0].balanceOf(address(vault)), 2 ether);
    intent.minUnderlying -= 1;
    book.requestRedemption(intent, amounts);
    assertTrue(book.usedRedemptionNonce(intent.epoch, intent.nonce));
    assertEq(book.redemptionUsedToday(0), 1.2 ether);
    intent.positionVersion = book.getPosition(0).version;
    vm.expectRevert(RedemptionAccounting.InvalidIntent.selector);
    book.requestRedemption(intent, amounts);
    _checkIndependentValuation(queue.nextId());
  }

  function _checkIndependentValuation(uint256 id) private {
    address markPublisher = address(0x0ba5e);
    LidoValuation marks = LidoValuation(address(valuation));
    uint256 nowTime = vm.getBlockTimestamp();
    vault.checkpointValuation();
    (,, bool fresh) = vault.valuationIdentity();
    assertTrue(fresh);
    vm.expectRevert(LidoValuation.Unauthorized.selector);
    marks.publish(1e18, 0.98e18, nowTime, nowTime + 60, 2);
    vm.prank(markPublisher);
    marks.publish(1e18, 0.98e18, nowTime, nowTime + 60, 2);
    (,, fresh) = vault.valuationIdentity();
    assertFalse(fresh); // Same timestamp, different actual mark: no stale LP issuance.
    assertEq(vault.maxDeposit(alice), 0);
    vault.checkpointValuation();
    (,, fresh) = vault.valuationIdentity();
    assertTrue(fresh);
    (uint256 nominal, uint256 mark,,,, bool valid) = marks.inventory(address(bases[0]), 1 ether);
    assertEq(nominal, 1.2 ether);
    assertEq(mark, nominal);
    assertTrue(valid);
    (mark,,, valid) = marks.claim(address(adapter), id, nominal);
    assertEq(mark, 1.176 ether);
    assertTrue(valid);
    vm.prank(markPublisher);
    vm.expectRevert(LidoValuation.InvalidObservation.selector);
    marks.publish(1e18, 0.98e18, nowTime, nowTime + 60, 1);
    vm.warp(nowTime + 61);
    (,,,,, valid) = marks.inventory(address(bases[0]), 1 ether);
    assertFalse(valid);
    queue.setFinalized(id, 0.8 ether);
    marks.revokePublisher();
    (mark,,, valid) = marks.claim(address(adapter), id, nominal);
    assertEq(mark, 0.8 ether); // Native finalization, not expired estimates.
    assertTrue(valid);
  }
}

contract LidoAdapterTest is LidoFixture {
  function test_MalformedIssuerRequestRollsBack() public {
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = amounts[1] = 1 ether;
    base.mint(address(adapter), 2 ether);
    for (uint256 fault = 1; fault <= 3; ++fault) {
      queue.setFault(fault);
      vm.expectRevert();
      adapter.request(amounts, 0);
      assertEq(queue.nextId(), 0);
      assertEq(base.balanceOf(address(adapter)), 2 ether);
      assertEq(base.allowance(address(adapter), address(queue)), 0);
      assertFalse(adapter.accepted(1));
    }
  }

  function test_ShortReceiptAndLiveRightCannotBeMarkedClosed() public {
    uint256 id = _request(1 ether);
    queue.setFinalized(id, 1.2 ether);
    for (uint256 fault = 4; fault <= 5; ++fault) {
      queue.setFault(fault);
      vm.expectRevert(AdapterBase.ReceiptMismatch.selector);
      adapter.claim(id, 1);
      assertFalse(adapter.closed(id));
      assertEq(weth.balanceOf(vault), 0);
      assertEq(queue.ownerOf(id), address(adapter));
    }
  }
}
