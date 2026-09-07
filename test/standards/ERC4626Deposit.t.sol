// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {HarborVault} from "src/vault/HarborVault.sol";
import {VaultFixture} from "test/helpers/VaultFixture.sol";

/// @title ERC4626DepositTest
/// @notice Issuance, conversion, caller-funded overloads and surplus exclusion.
contract ERC4626DepositTest is VaultFixture {
  function testFuzz_DepositAndMintMatchPreviews(uint64 amount_) public {
    uint256 amount = bound(amount_, 1e12, 10 ether);
    uint256 expected = vault.previewDeposit(amount);
    assertEq(_deposit(alice, amount), expected);
    uint256 shares = expected / 3 + 1;
    uint256 assets = vault.previewMint(shares);
    vm.prank(bob);
    assertEq(vault.mint(shares, bob), assets);
    assertEq(vault.balanceOf(bob), shares);
    assertEq(vault.totalAssets(), amount + assets);
  }

  function test_DonationsDoNotChangeNAVOrDiluteNewDepositors() public {
    uint256 shares = _deposit(alice, 1 ether);
    weth.mint(address(vault), 1000 ether);
    assertEq(vault.totalAssets(), 1 ether);
    assertEq(_deposit(bob, 1 ether), shares);
    assertEq(vault.totalAssets(), 2 ether);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 2 ether);
  }

  function test_OverloadRequiresControllerPermissionButCollectsFromCaller() public {
    vm.prank(alice);
    vault.setOperator(bob, true);
    vm.prank(bob);
    vault.deposit(1 ether, alice, alice);
    assertEq(weth.balanceOf(alice), 100 ether);
    assertEq(weth.balanceOf(bob), 99 ether);
    assertEq(vault.balanceOf(alice), 1 ether * 1e6);
    vm.expectRevert(HarborVault.Unauthorized.selector);
    vm.prank(operator);
    vault.mint(1e6, alice, alice);
  }

  function test_StaleValuationBlocksIssuanceButNotRequests() public {
    uint256 shares = _deposit(alice, 1 ether);
    vm.warp(1061);
    assertEq(vault.maxDeposit(alice), 0);
    vm.expectRevert(HarborVault.ValuationUnavailable.selector);
    vm.prank(alice);
    vault.deposit(1 ether, alice);
    _request(alice, shares);
  }

  function test_TransfersDoNotCreateYieldAndEscrowCannotBeReused() public {
    uint256 shares = _deposit(alice, 1 ether);
    vm.prank(alice);
    vault.transfer(bob, shares / 2);
    assertEq(vault.totalAssets(), 1 ether);
    assertEq(vault.totalSupply(), shares);
    _request(bob, shares / 2);
    vm.expectRevert(HarborVault.InvalidReceiver.selector);
    vault.transferFrom(address(vault), alice, shares / 2);
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

  function test_ZeroSharesAndTinySeedRejected() public {
    vm.expectRevert(HarborVault.InvalidAmount.selector);
    vm.prank(alice);
    vault.deposit(1, alice);
    vm.expectRevert(HarborVault.InvalidAmount.selector);
    vm.prank(alice);
    vault.mint(0, alice);
  }
}
