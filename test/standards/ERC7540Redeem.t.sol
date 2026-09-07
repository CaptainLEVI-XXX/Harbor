// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {VaultState} from "src/vault/base/VaultState.sol";

import {HarborVault} from "src/vault/HarborVault.sol";
import {VaultFixture} from "test/helpers/VaultFixture.sol";

/// @title ERC7540RedeemTest
/// @notice Pending, funded and claimed states remain separate and controller-owned.
contract ERC7540RedeemTest is VaultFixture {
  function test_Permit2HasNoImplicitShareAllowance() public {
    uint256 shares = _deposit(alice, 1 ether);
    address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    assertEq(vault.allowance(alice, permit2), 0);
    vm.expectRevert();
    vm.prank(permit2);
    vault.requestRedeem(shares, permit2, alice);
    vm.expectRevert();
    vm.prank(permit2);
    vault.transferFrom(alice, permit2, shares);
  }

  function test_RequestEscrowsThenFundingBurnsThenClaimPays() public {
    uint256 shares = _deposit(alice, 10 ether);
    _request(alice, shares);
    assertEq(vault.totalSupply(), shares);
    assertEq(vault.balanceOf(address(vault)), shares);
    assertEq(vault.maxWithdraw(alice), 0);
    assertEq(vault.maxRedeem(alice), 0);
    assertEq(vault.pendingRedeemRequest(0, alice), shares);
    assertEq(vault.pendingRedeemRequest(1, alice), 0);
    vault.fulfillWithdrawals(8);
    assertEq(vault.totalSupply(), 0);
    assertEq(vault.totalAssets(), 0);
    assertEq(vault.claimableRedeemRequest(0, alice), shares);
    assertEq(vault.maxWithdraw(alice), 10 ether);
    assertEq(weth.balanceOf(alice), 90 ether);
    vm.prank(alice);
    assertEq(vault.redeem(shares, alice, alice), 10 ether);
    assertEq(weth.balanceOf(alice), 100 ether);
    assertEq(vault.maxRedeem(alice), 0);
  }

  function test_SynchronousExitCannotBypassRequest() public {
    uint256 shares = _deposit(alice, 10 ether);
    vm.expectRevert();
    vm.prank(alice);
    vault.redeem(shares, alice, alice);
    vm.expectRevert(VaultState.AsyncPreview.selector);
    vault.previewRedeem(1);
    vm.expectRevert(VaultState.AsyncPreview.selector);
    vault.previewWithdraw(1);
  }

  function test_FundedClaimsSurviveStaleMarksAndRevokedDepositApproval() public {
    uint256 shares = _deposit(alice, 10 ether);
    _request(alice, shares);
    vault.fulfillWithdrawals(1);
    vm.warp(2000);
    book.setMark(0, 0, 1000, false);
    vm.prank(alice);
    weth.approve(address(vault), 0);
    assertEq(vault.maxDeposit(alice), 0);
    assertEq(vault.maxWithdraw(alice), 10 ether);
    vm.prank(alice);
    assertEq(vault.withdraw(4 ether, alice, alice), 4 ether * 1e6);
    vm.prank(alice);
    assertEq(vault.redeem(6 ether * 1e6, alice, alice), 6 ether);
  }

  function test_OperatorPrecedenceAndRevocationPreserveCredit() public {
    uint256 shares = _deposit(alice, 10 ether);
    vm.prank(alice);
    vault.approve(operator, 1);
    vm.prank(alice);
    vault.setOperator(operator, true);
    vm.prank(operator);
    vault.requestRedeem(shares, alice, alice);
    assertEq(vault.allowance(alice, operator), 1);
    vault.fulfillWithdrawals(1);
    vm.prank(alice);
    vault.setOperator(operator, false);
    vm.expectRevert(VaultState.Unauthorized.selector);
    vm.prank(operator);
    vault.redeem(shares, operator, alice);
    assertEq(vault.maxRedeem(alice), shares);
    vm.prank(alice);
    vault.redeem(shares, alice, alice);
  }

  function test_AllowanceCanRequestButCannotClaimControllerCredit() public {
    uint256 shares = _deposit(alice, 10 ether);
    vm.prank(alice);
    vault.approve(operator, shares);
    vm.prank(operator);
    vault.requestRedeem(shares, alice, alice);
    assertEq(vault.allowance(alice, operator), 0);
    vault.fulfillWithdrawals(1);
    vm.expectRevert(VaultState.Unauthorized.selector);
    vm.prank(operator);
    vault.withdraw(10 ether, operator, alice);
  }

  function test_FundingIsBoundedAndFIFO() public {
    uint256 shares = _deposit(alice, 10 ether);
    uint256 bobShares = _deposit(bob, 10 ether);
    _request(alice, shares);
    _request(bob, bobShares);
    vm.expectRevert(VaultState.InvalidAmount.selector);
    vault.fulfillWithdrawals(9);
    vault.fulfillWithdrawals(1);
    assertEq(vault.maxRedeem(alice), shares);
    assertEq(vault.maxRedeem(bob), 0);
    assertEq(vault.pendingRedeemRequest(0, bob), bobShares);
    vault.fulfillWithdrawals(1);
    assertEq(vault.maxRedeem(bob), bobShares);
  }

  function test_InterfacesAndShareLookup() public view {
    assertEq(vault.share(), address(vault));
    assertEq(vault.vault(address(weth)), address(vault));
    assertEq(vault.vault(address(1)), address(0));
    assertTrue(vault.supportsInterface(0x620ee8e4));
    assertTrue(vault.supportsInterface(0xe3bc4e65));
    assertTrue(vault.supportsInterface(0x2f0a18c5));
    assertTrue(vault.supportsInterface(0xf815c03d));
    assertTrue(vault.supportsInterface(0x01ffc9a7));
    assertFalse(vault.supportsInterface(0xce3bbe50));
    assertFalse(vault.supportsInterface(0xffffffff));
  }

  function test_ReserveDeficitBlocksFirstComeDepletion() public {
    uint256 a = _deposit(alice, 10 ether);
    uint256 b = _deposit(bob, 10 ether);
    _request(alice, a);
    _request(bob, b);
    vault.fulfillWithdrawals(2);
    // Synthetic loss of custody: genuine WETH is not assumed to have this power.
    deal(address(weth), address(vault), 15 ether);
    assertEq(vault.maxWithdraw(alice), 0);
    assertEq(vault.maxWithdraw(bob), 0);
    (,,, bool valid, bool insolvent) = vault.accountingStatus();
    assertFalse(valid);
    assertTrue(insolvent);
    vm.expectRevert();
    vm.prank(alice);
    vault.withdraw(10 ether, alice, alice);
    assertEq(vault.claimableRedeemRequest(0, alice), a);
  }

  function test_PartialFundingDoesNotSkipHead() public {
    uint256 a = _deposit(alice, 10 ether);
    uint256 b = _deposit(bob, 10 ether);
    // Synthetic unrealized mark solely to exercise cash-limited fulfillment.
    book.setMark(40 ether, 0, 1000, true);
    vault.checkpointValuation();
    _request(alice, a);
    _request(bob, b);
    vault.fulfillWithdrawals(8);
    assertGt(vault.pendingRedeemRequest(0, alice), 0);
    assertGt(vault.claimableRedeemRequest(0, alice), 0);
    assertEq(vault.claimableRedeemRequest(0, bob), 0);
    assertEq(vault.pendingRedeemRequest(0, bob), b);
    (, uint256 reserved,,,) = vault.accountingStatus();
    assertLe(reserved, weth.balanceOf(address(vault)));
  }
}
