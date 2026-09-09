// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {VaultState} from "src/vault/base/VaultState.sol";

import {IssuerFixture} from "test/helpers/IssuerFixture.sol";
import {BookAccounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {RedemptionAccounting} from "src/libraries/RedemptionAccounting.sol";
import {BookState} from "src/book/base/BookState.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {RedeemIntent} from "src/types/HarborTypes.sol";
import {RealizationLogs} from "test/helpers/RealizationLogs.sol";

contract IssuerRecoveryTest is IssuerFixture {
  function test_PurchaseBecomesClaimNotCashThenMeasuredRecovery() public {
    _buy(0, 2 ether);
    (uint256 beforeCash,,,,) = vault.accountingStatus();
    uint256 id = _request(1 ether);
    BookAccounting.Position memory p = book.getPosition(0);
    ClaimAccounting.Claim memory c = book.getClaim(address(adapter), id);
    assertEq(p.shares, 1 ether);
    assertEq(p.basis, 0.99 ether);
    assertEq(p.pendingBasis, 0.99 ether);
    assertEq(c.remaining, 1.2 ether);
    assertEq(c.received, 0);
    assertEq(queue.ownerOf(id), address(adapter));
    (uint256 cash,,,,) = vault.accountingStatus();
    assertEq(cash, beforeCash);
    assertEq(vault.maxDeposit(alice), 0);
    assertEq(bases[0].allowance(address(vault), address(book)), 0);
    vault.checkpointValuation(); // Synthetic public claim mark, not a production mark.
    assertEq(vault.totalAssets(), beforeCash + 1 ether + 1.2 ether);
    queue.setFinalized(id, 1.19 ether);
    vm.recordLogs();
    _claim(id);
    p = book.getPosition(0);
    c = book.getClaim(address(adapter), id);
    assertEq(p.pendingBasis, 0);
    (uint256 gains,, uint256 count) = RealizationLogs.totals(vm.getRecordedLogs(), address(book), 0);
    assertEq(gains, 0.2 ether);
    assertEq(count, 1);
    assertEq(c.received, 0);
    assertEq(c.basis, 0);
    assertTrue(c.closed);
    (cash,,,,) = vault.accountingStatus();
    assertEq(cash, beforeCash + 1.19 ether);
    assertEq(vault.maxDeposit(alice), 0); // Recovery does not invent fresh valuation.
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), cash + 1 ether);
  }

  function test_StopRevocationAndValuationOutagePreserveRecovery() public {
    _buy(0, 1 ether);
    uint256 id = _request(1 ether);
    book.stopTrading();
    book.revokeKeeper();
    valuation.setValid(false);
    vm.warp(1 days);
    queue.setFinalized(id, 1.1 ether);
    _claim(id);
    assertTrue(book.getClaim(address(adapter), id).closed);
    assertEq(vault.maxDeposit(alice), 0);
  }

  function test_RecoveryFundsPendingFIFOExitsUsingActualWETH() public {
    _buy(0, 20 ether);
    uint256 id = _request(20 ether);
    vault.checkpointValuation();
    uint256 shares = vault.balanceOf(alice);
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    vault.fulfillWithdrawals(1);
    assertGt(vault.pendingRedeemRequest(0, alice), 0);
    assertEq(vault.maxWithdraw(alice), 0.2 ether);
    queue.setFinalized(id, 23 ether);
    _claim(id);
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

  function test_LossAboveBudgetIsRecordedRatherThanBlockingRecovery() public {
    _buy(0, 20 ether);
    uint256 id = _request(20 ether);
    queue.setFinalized(id, 0);
    _claim(id);
    assertEq(book.getPosition(0).realizedLosses, 19.8 ether);
    assertEq(book.getPosition(0).pendingBasis, 0);
    assertTrue(book.getClaim(address(adapter), id).closed);
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
  }

  function test_RequestSplitConservesAllBasis() public {
    _buy(0, 2 ether);
    uint256[] memory amounts = new uint256[](3);
    amounts[0] = 1 ether;
    amounts[1] = 0.5 ether;
    amounts[2] = 0.5 ether;
    book.requestRedemption(_intent(amounts), amounts);
    uint256 assigned;
    for (uint256 i = 1; i <= 3; ++i) {
      assigned += book.getClaim(address(adapter), i).basis;
    }
    assertEq(assigned, 1.98 ether);
    assertEq(book.getPosition(0).basis, 0);
    assertEq(book.getPosition(0).pendingBasis, assigned);
  }

  function test_FailedClaimDoesNotAffectOtherReadyRights() public {
    _buy(0, 2 ether);
    uint256 first = _request(1 ether);
    uint256 second = _request(1 ether);
    queue.setFinalized(second, 1.2 ether);
    _claim(second);
    assertTrue(book.getClaim(address(adapter), second).closed);
    assertFalse(book.getClaim(address(adapter), first).closed);
  }

  function test_TypedGatewayCannotBeUsedOutsideExactBookOperation() public {
    vm.expectRevert(VaultState.Unauthorized.selector);
    vault.transferForRedemption(bytes32(uint256(1)));
    vm.prank(address(book));
    vm.expectRevert(VaultState.InvalidContext.selector);
    vault.transferForRedemption(bytes32(uint256(1)));
    vm.expectRevert(BookState.Unauthorized.selector);
    book.redemptionTransfer(bytes32(uint256(1)));
  }
}
