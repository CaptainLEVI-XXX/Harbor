// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {VaultAccounting as Accounting} from "src/libraries/VaultAccounting.sol";
import {WithdrawalQueue as Queue} from "src/libraries/WithdrawalQueue.sol";

contract VaultAccountingHarness {
  using Accounting for Accounting.State;
  using Queue for Queue.State;
  Accounting.State private state;

  function receipt(uint256 a) external {
    state.receiveCash(a);
  }

  function spend(uint256 a, uint256 b) external {
    state.spendCash(a, b);
  }

  function checkpoint(uint256 w, uint256 p, uint256 s, uint256 t) external {
    state.checkpoint(w, p, s, t, 1, 60);
  }

  function reserve(uint256 s, uint256 a, uint256 supply) external {
    state.withdrawals.append(address(1), s);
    state.withdrawals.fundHead(s, a);
    state.commit(supply);
  }

  function claim(uint256 s, uint256 supply) external {
    uint256 a = state.withdrawals.redeem(address(1), s);
    state.cash -= a;
    state.commit(supply);
  }

  function backed(uint256 actual) external view {
    state.requireBacked(actual);
  }

  function viewState()
    external
    view
    returns (uint256 cash, uint256 nav, uint256 supply, uint256 free, bool fresh, bool insolvent)
  {
    return (state.cash, state.nav, state.supply, state.available(0), state.fresh(60), state.insolvent);
  }
}

/// @title VaultAccountingTest
/// @notice Cash capacity is independent of inventory and pending-right marks.
contract VaultAccountingTest is Test {
  VaultAccountingHarness internal h = new VaultAccountingHarness();

  function setUp() public {
    vm.warp(1000);
  }

  function test_PendingRightsAndInventoryAreNotCash() public {
    h.receipt(10);
    h.checkpoint(20, 30, 60, 1000);
    (uint256 cash, uint256 nav,, uint256 free, bool fresh,) = h.viewState();
    assertEq(cash, 10);
    assertEq(nav, 60);
    assertEq(free, 10);
    assertTrue(fresh);
    vm.expectRevert(abi.encodeWithSelector(Accounting.ReservedCash.selector, 10, 11));
    h.spend(11, 0);
  }

  function test_FulfillmentRemovesNAVAndClaimsLeaveNAVUnchanged() public {
    h.receipt(100);
    h.checkpoint(0, 0, 100, 1000);
    h.reserve(20, 20, 80);
    (, uint256 nav, uint256 supply, uint256 free,,) = h.viewState();
    assertEq(nav, 80);
    assertEq(supply, 80);
    assertEq(free, 80);
    h.claim(20, 80);
    (uint256 cash, uint256 afterNav,,, bool fresh,) = h.viewState();
    assertEq(cash, 80);
    assertEq(afterNav, nav);
    assertTrue(fresh);
  }

  function test_StaleAndChangedPortfolioInvalidateMarks() public {
    h.checkpoint(0, 0, 0, 1000);
    vm.warp(1061);
    (,,,, bool fresh,) = h.viewState();
    assertFalse(fresh);
    h.checkpoint(0, 0, 0, 1061);
    h.receipt(1);
    (,,,, fresh,) = h.viewState();
    assertFalse(fresh);
  }

  function test_SurplusIsNotRecognizedAndDeficitIsDetected() public {
    h.receipt(10);
    h.checkpoint(0, 0, 10, 1000);
    h.backed(20);
    (uint256 cash,,,,,) = h.viewState();
    assertEq(cash, 10);
    vm.expectRevert(abi.encodeWithSelector(Accounting.CashDeficit.selector, 9, 10));
    h.backed(9);
  }

  function test_LiabilityDeficitNotHiddenByNAVFloor() public {
    h.checkpoint(0, 0, 10, 1000);
    // Synthetic accounting corruption to exercise telemetry, not lawful funding.
    h.reserve(10, 1, 0);
    (, uint256 nav,,, bool fresh, bool insolvent) = h.viewState();
    assertEq(nav, 0);
    assertTrue(insolvent);
    assertFalse(fresh);
  }
}
