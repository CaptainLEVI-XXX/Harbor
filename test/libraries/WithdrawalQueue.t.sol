// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {WithdrawalQueue as Queue} from "src/libraries/WithdrawalQueue.sol";

contract QueueHarness {
  using Queue for Queue.State;
  Queue.State private state;

  function append(address c, uint256 u) external returns (uint256) {
    return state.append(c, u);
  }

  function fund(uint256 u, uint256 a) external returns (address) {
    return state.fundHead(u, a);
  }

  function redeem(address c, uint256 u) external returns (uint256) {
    return state.redeem(c, u);
  }

  function withdraw(address c, uint256 a) external returns (uint256) {
    return state.withdraw(c, a);
  }

  function credit(address c) external view returns (Queue.Credit memory) {
    return state.credits[c];
  }

  function totals() external view returns (uint256, uint256, uint256, uint256) {
    return (state.head, state.tail, state.totalPending, state.reserved);
  }

  function fundable(uint256 p, uint256 c, uint256 n, uint256 d) external pure returns (uint256, uint256) {
    return Queue.fundable(p, c, n, d);
  }
}

/// @title WithdrawalQueueTest
/// @notice Synthetic FIFO, loss credits, aggregate rates and exact rounding tests.
contract WithdrawalQueueTest is Test {
  QueueHarness internal h = new QueueHarness();
  address internal constant A = address(1);
  address internal constant B = address(2);

  function test_FIFOWithPartialHeadAndMixedRates() public {
    assertEq(h.append(A, 10), 0);
    assertEq(h.append(B, 10), 1);
    assertEq(h.fund(4, 8), A);
    assertEq(h.credit(A).pending, 6);
    assertEq(h.credit(B).units, 0);
    assertEq(h.fund(6, 6), A);
    assertEq(h.fund(10, 5), B);
    assertEq(h.credit(A).units, 10);
    assertEq(h.credit(A).assets, 14);
    assertEq(h.redeem(A, 3), 4);
    assertEq(h.redeem(A, 7), 10);
    (uint256 head, uint256 tail, uint256 pending, uint256 reserved) = h.totals();
    assertEq(head, tail);
    assertEq(pending, 0);
    assertEq(reserved, 5);
  }

  function test_LastReceiptCannotStrandCash() public {
    h.append(A, 1);
    h.fund(1, 10);
    vm.expectRevert(abi.encodeWithSelector(Queue.ClaimAllAssets.selector, 10));
    h.withdraw(A, 9);
    assertEq(h.withdraw(A, 10), 1);
  }

  function test_ZeroValueCreditStillRequiresAcknowledgement() public {
    h.append(A, 100);
    h.fund(100, 0);
    assertEq(h.credit(A).units, 100);
    assertEq(h.redeem(A, 100), 0);
    assertEq(h.credit(A).units, 0);
    vm.expectRevert(Queue.InsufficientCredit.selector);
    h.redeem(A, 100);
  }

  function test_TinyNonzeroNAVDoesNotForceZeroValueExit() public view {
    (uint256 shares, uint256 assets) = h.fundable(1, 10, 1, 100);
    assertEq(shares, 0);
    assertEq(assets, 0);
    (shares, assets) = h.fundable(1, 0, 0, 100);
    assertEq(shares, 1);
    assertEq(assets, 0);
  }

  function testFuzz_FundingMatchesBruteForce(uint8 pending_, uint8 cash_, uint8 n_, uint8 d_) public view {
    uint256 pending = pending_;
    uint256 cash = cash_;
    uint256 n = n_;
    uint256 d = uint256(d_) + 1;
    uint256 best;
    for (uint256 i; i <= pending; ++i) {
      if (i * n / d <= cash) best = i;
    }
    uint256 cost = best * n / d;
    if (n != 0 && cost == 0) best = 0;
    (uint256 shares, uint256 assets) = h.fundable(pending, cash, n, d);
    assertEq(shares, best);
    assertEq(assets, cost);
  }

  function testFuzz_PartialRedemptionsConserveAllReservedCash(uint128 units_, uint128 assets, uint128 cut_) public {
    uint256 units = uint256(units_) + 1;
    uint256 cut = uint256(cut_) % units + 1;
    h.append(A, units);
    h.fund(units, assets);
    uint256 first = h.redeem(A, cut);
    assertEq(first, cut * uint256(assets) / units);
    uint256 last = cut == units ? 0 : h.redeem(A, units - cut);
    assertEq(first + last, assets);
    (,,, uint256 reserved) = h.totals();
    assertEq(reserved, 0);
  }
}
