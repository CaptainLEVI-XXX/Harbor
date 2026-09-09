// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {VaultState} from "src/vault/base/VaultState.sol";

import {HarborVault} from "src/vault/HarborVault.sol";
import {VaultFixture} from "test/helpers/VaultFixture.sol";

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
    vault.checkpointValuation();
    uint256 shares = expected / 3 + 1;
    uint256 numerator = shares * (amount + 1 ether + 1);
    uint256 denominator = expected + 1e6;
    uint256 assets = (numerator - 1) / denominator + 1; // Required WETH rounds up.
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

  function test_DonationsDoNotChangeNAVOrDiluteNewDepositors() public {
    uint256 shares = _deposit(alice, 1 ether);
    weth.mint(address(vault), 1000 ether);
    assertEq(vault.totalAssets(), 1 ether);
    assertEq(_deposit(bob, 1 ether), shares);
    assertEq(vault.totalAssets(), 2 ether);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 2 ether);
  }

  function test_StaleValuationBlocksIssuanceButNotRequests() public {
    uint256 shares = _deposit(alice, 1 ether);
    vm.warp(1061);
    assertEq(vault.maxDeposit(alice), 0);
    vm.expectRevert(VaultState.ValuationUnavailable.selector);
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
    vm.expectRevert(VaultState.InvalidReceiver.selector);
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
    vm.expectRevert(VaultState.InvalidAmount.selector);
    vm.prank(alice);
    vault.deposit(1, alice);
    vm.expectRevert(VaultState.InvalidAmount.selector);
    vm.prank(alice);
    vault.mint(0, alice);
  }
}
