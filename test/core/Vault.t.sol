// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {VaultCore} from "src/vault/base/VaultCore.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {VaultFixture} from "test/base/VaultFixture.sol";

/// @title ERC4626DepositTest
/// @notice Issuance, conversion, caller-funded overloads and surplus exclusion.
contract ERC4626DepositTest is VaultFixture {
  function testFuzz_DepositAndMintFollowIndependentRounding(uint64 amount_) public {
    uint256 amount = bound(amount_, 1e12, 10 ether);
    uint256 expected = amount * 1e6; // Empty pool: one virtual wei and 1e6 virtual shares.
    assertEq(vault.previewDeposit(amount), expected);
    assertEq(_deposit(alice, amount), expected);

    // Synthetic noncash gain creates a nontrivial exchange rate for mint rounding.
    book.setMark(1 ether, 0, block.timestamp, true);
    uint256 shares = expected / 3 + 1;
    uint256 numerator = shares * (amount + 1 ether + 1);
    uint256 denominator = expected + 1e6;
    uint256 assets = (numerator - 1) / denominator + 1; // Required ASSET rounds up.
    assertEq(vault.previewMint(shares), assets);
    vm.prank(bob);
    assertEq(vault.mint(shares, bob), assets);
    assertEq(vault.balanceOf(bob), shares);
    assertEq(vault.totalSupply(), expected + shares);
    assertEq(weth.balanceOf(alice), 100 ether - amount);
    assertEq(weth.balanceOf(bob), 100 ether - assets);
    assertEq(weth.balanceOf(address(vault)), amount + assets);
    assertEq(vault.totalAssets(), amount + 1 ether + assets);
  }

  function test_DonationsAndIndependentDepositMintLimits() public {
    uint256 snapshot = vm.snapshotState();
    uint256 maximum = vault.maxDeposit(alice);
    assertEq(maximum, (type(uint256).max - 1e6 + 1) / 1e6);
    weth.mint(alice, maximum);
    vm.prank(alice);
    vault.deposit(maximum, alice);
    assertEq(vault.totalSupply(), maximum * 1e6);
    assertEq(vault.totalAssets(), maximum);
    // Deposit rounding cannot fit another asset wei, but an exact-share mint
    // can consume the remaining share room for one wei. Do not couple the limits.
    assertEq(vault.maxDeposit(alice), 0);
    uint256 remainingShares = type(uint256).max - 1e6 - maximum * 1e6;
    assertGt(remainingShares, 0);
    assertEq(vault.maxMint(alice), remainingShares);
    vm.prank(alice);
    assertEq(vault.mint(remainingShares, alice), 1);
    assertEq(vault.totalSupply(), type(uint256).max - 1e6);
    assertEq(vault.totalAssets(), maximum + 1);
    assertEq(vault.balanceOf(alice), type(uint256).max - 1e6);
    assertEq(weth.balanceOf(address(vault)), maximum + 1);
    assertEq(vault.maxMint(alice), 0);
    assertEq(vault.maxDeposit(alice), 0);
    assertTrue(vm.revertToState(snapshot));
    maximum = vault.maxMint(alice);
    assertEq(maximum, type(uint256).max - 1e6);
    uint256 assets = vault.previewMint(maximum);
    weth.mint(alice, assets);
    vm.prank(alice);
    vault.mint(maximum, alice);
    assertEq(vault.totalSupply(), maximum);
    assertEq(vault.maxMint(alice), 0);
    assertEq(vault.maxDeposit(alice), 0);
    assertTrue(vm.revertToState(snapshot));
    uint256 shares = _deposit(alice, 1 ether);
    weth.mint(address(vault), 1000 ether);
    assertEq(vault.totalAssets(), 1 ether);
    assertEq(_deposit(bob, 1 ether), shares);
    assertEq(vault.totalAssets(), 2 ether);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 2 ether);
  }

  function test_FinishFailureRollsBackDepositAndNextOperationWorks() public {
    book.setFailFinish(true);
    vm.expectRevert(bytes("book finish"));
    vm.prank(alice);
    vault.deposit(1 ether, alice);
    assertEq(weth.balanceOf(alice), 100 ether);
    assertEq(vault.totalSupply(), 0);
    book.setFailFinish(false);
    _deposit(alice, 1 ether);
    _deposit(bob, 1 ether);
    assertEq(vault.totalAssets(), 2 ether);
  }

  function test_IssuanceRefreshesInvalidatedNavButRejectsBadMarksAndDeficits() public {
    _deposit(alice, 2 ether);
    vm.prank(address(book));
    vault.invalidateValuation();
    book.setMark(1 ether, 0, block.timestamp, true);
    (,,, bool cachedValid,) = vault.accountingStatus();
    assertFalse(cachedValid);
    assertGt(vault.maxDeposit(bob), 0);
    uint256 expected = uint256(1 ether) * (2 ether * 1e6 + 1e6) / (3 ether + 1);
    assertEq(vault.previewDeposit(1 ether), expected);
    vm.prank(bob);
    assertEq(vault.deposit(1 ether, bob, bob), expected);
    assertEq(vault.totalAssets(), 4 ether);
    book.setMark(0.5 ether, 0, block.timestamp, true);
    uint256 shares = 1e23;
    uint256 numerator = shares * (3.5 ether + 1);
    uint256 denominator = vault.totalSupply() + 1e6;
    uint256 assets = (numerator - 1) / denominator + 1;
    assertEq(vault.previewMint(shares), assets);
    vm.prank(bob);
    assertEq(vault.mint(shares, bob, bob), assets);
    uint256 cash = weth.balanceOf(address(vault));
    uint256 supply = vault.totalSupply();
    book.setMark(0.5 ether, 0, block.timestamp, false);
    assertEq(vault.maxDeposit(bob), 0);
    vm.expectRevert(VaultCore.ValuationUnavailable.selector);
    vault.previewDeposit(1 ether);
    vm.expectRevert(VaultCore.ValuationUnavailable.selector);
    vm.prank(bob);
    vault.deposit(1 ether, bob);
    book.setMark(0.5 ether, 0, block.timestamp - 61, true);
    assertEq(vault.maxMint(bob), 0);
    vm.expectRevert();
    vm.prank(bob);
    vault.mint(shares, bob);
    assertEq(weth.balanceOf(address(vault)), cash);
    assertEq(vault.totalSupply(), supply);
    book.setMark(0.5 ether, 0, block.timestamp, true);
    deal(address(weth), address(vault), cash - 1);
    assertEq(vault.maxDeposit(bob), 0);
    vm.expectRevert();
    vm.prank(bob);
    vault.deposit(1 ether, bob);
    assertEq(vault.totalSupply(), supply);
  }
}

/// @title ERC7540RedeemTest
/// @notice Pending, funded and claimed states remain separate and controller-owned.
contract ERC7540RedeemTest is VaultFixture {
  function test_CombinedExitRefreshesAndPaysOrQueuesBehindEarlierRequests() public {
    uint256 a = _deposit(alice, 2 ether);
    uint256 b = _deposit(bob, 2 ether);
    vm.prank(address(book));
    vault.invalidateValuation();
    vm.prank(alice);
    assertEq(vault.requestRedeemAndClaim(a / 2, alice, 8, 1 ether), 1 ether);
    assertEq(weth.balanceOf(alice), 99 ether);
    assertEq(vault.balanceOf(alice), a / 2);
    assertEq(vault.claimableRedeemRequest(0, alice), 0);
    assertEq(vault.totalAssets(), 3 ether);

    _request(bob, b);
    // Independently observed noncash backing raises the exit value above cash.
    // Funding must refresh the changed mark, reserve only cash and stop at Bob.
    book.setMark(3 ether, 0, block.timestamp, true);
    vm.expectRevert(VaultCore.InvalidAmount.selector);
    vm.prank(alice);
    vault.requestRedeemAndClaim(a / 2, alice, 8, 1);
    assertEq(vault.pendingRedeemRequest(0, alice), 0);
    assertEq(vault.pendingRedeemRequest(0, bob), b);
    assertEq(vault.claimableRedeemRequest(0, bob), 0); // Minimum failure rolled back funding too.
    vm.prank(alice);
    assertEq(vault.requestRedeemAndClaim(a / 2, alice, 8, 0), 0);
    assertEq(vault.pendingRedeemRequest(0, alice), a / 2);
    assertGt(vault.pendingRedeemRequest(0, bob), 0);
    assertEq(vault.maxWithdraw(bob), 3 ether);
    assertEq(vault.maxWithdraw(alice), 0);
    (uint256 cash, uint256 reserved,,,) = vault.accountingStatus();
    assertEq(cash, reserved);
    assertEq(reserved, 3 ether);

    book.setMark(3 ether, 0, block.timestamp, false);
    vm.expectRevert(VaultCore.ValuationUnavailable.selector);
    vault.fulfillWithdrawals(8);
    vm.expectRevert(VaultCore.Unauthorized.selector);
    vm.prank(alice);
    vault.withdraw(3 ether, alice, bob);
    uint256 funded = vault.claimableRedeemRequest(0, bob);
    vm.prank(bob);
    assertEq(vault.redeem(funded, bob, bob), 3 ether);
    assertEq(weth.balanceOf(bob), 101 ether);
    assertEq(weth.balanceOf(address(vault)), 0);
    assertEq(vault.maxWithdraw(bob), 0);
    vm.expectRevert();
    vm.prank(bob);
    vault.withdraw(1, bob, bob);
    assertEq(vault.pendingRedeemRequest(0, alice), a / 2);
  }

  function test_AllowanceCanRequestButCannotClaimControllerCredit() public {
    uint256 shares = _deposit(alice, 10 ether);
    vm.prank(alice);
    vault.approve(operator, shares);
    vm.prank(operator);
    vault.requestRedeem(shares, alice, alice);
    assertEq(vault.allowance(alice, operator), 0);
    vault.fulfillWithdrawals(1);
    vm.expectRevert(VaultCore.Unauthorized.selector);
    vm.prank(operator);
    vault.withdraw(10 ether, operator, alice);
  }

  function test_ReserveDeficitBlocksFirstComeDepletion() public {
    uint256 a = _deposit(alice, 10 ether);
    uint256 b = _deposit(bob, 10 ether);
    _request(alice, a);
    _request(bob, b);
    vault.fulfillWithdrawals(2);
    // Synthetic loss of custody: genuine ASSET is not assumed to have this power.
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
}
