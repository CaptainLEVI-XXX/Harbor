// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BookAccounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";

contract AccountingHarness {
  using BookAccounting for BookAccounting.State;
  BookAccounting.State private state;

  function buy(uint256 route, uint256 shares, uint256 cost) external {
    state.buy(route, shares, cost);
  }

  function sell(uint256 route, uint256 shares, uint256 revenue) external returns (uint256) {
    return state.sell(route, shares, revenue);
  }

  function request(uint256 route, uint256 shares, bytes32 id, uint256 entitlement) external returns (uint256) {
    return state.request(route, shares, id, entitlement);
  }

  function recover(bytes32 id, uint256 cash, uint256 remaining) external {
    state.recover(id, cash, remaining);
  }

  function position(uint256 route) external view returns (BookAccounting.Position memory) {
    return state.positions[route];
  }

  function claim(bytes32 id) external view returns (ClaimAccounting.Claim memory) {
    return state.claims.claims[id];
  }

  function active() external view returns (bytes32[] memory) {
    return state.claims.active;
  }
}

/// @title BookAccountingTest
/// @notice Cost conservation through synthetic partial recoveries and losses.
contract BookAccountingTest is Test {
  AccountingHarness internal h = new AccountingHarness();

  function testFuzz_FinalInventoryRemovalTakesBasisRemainder(uint128 cost, uint64 quantity, uint64 part) public {
    uint256 shares = uint256(quantity) + 1;
    uint256 cut = uint256(part) % shares + 1;
    uint256 basis = uint256(cost) + 1;
    h.buy(0, shares, basis);
    uint256 assigned = h.sell(0, cut, 0);
    assertEq(assigned, basis * cut / shares);
    if (cut != shares) assertEq(h.sell(0, shares - cut, 0), basis - assigned);
    BookAccounting.Position memory p = h.position(0);
    assertEq(p.shares, 0);
    assertEq(p.basis, 0);
    assertEq(p.realizedLosses, basis);
  }

  function test_RequestDoesNotReleaseExposureAndPartialCashDoesNotClose() public {
    h.buy(0, 3, 10);
    assertEq(h.request(0, 1, bytes32(uint256(1)), 5), 3);
    BookAccounting.Position memory p = h.position(0);
    assertEq(p.basis + p.pendingBasis, 10);
    h.recover(bytes32(uint256(1)), 2, 3);
    p = h.position(0);
    assertEq(p.pendingBasis, 3);
    assertEq(p.realizedGains, 0);
    assertFalse(h.claim(bytes32(uint256(1))).closed);
    h.recover(bytes32(uint256(1)), 2, 0);
    p = h.position(0);
    assertEq(p.pendingBasis, 0);
    assertEq(p.realizedGains, 1);
    assertEq(h.active().length, 0);
    vm.expectRevert(abi.encodeWithSelector(ClaimAccounting.InactiveClaim.selector, bytes32(uint256(1))));
    h.recover(bytes32(uint256(1)), 2, 0);
  }

  function test_UnavoidableLossRecognizedAndProfitDoesNotResetLoss() public {
    h.buy(0, 10, 100);
    h.request(0, 10, bytes32(uint256(1)), 100);
    h.recover(bytes32(uint256(1)), 1, 0);
    h.buy(0, 10, 100);
    h.sell(0, 10, 200);
    BookAccounting.Position memory p = h.position(0);
    assertEq(p.realizedLosses, 99);
    assertEq(p.realizedGains, 100);
    assertEq(p.pendingBasis, 0);
  }

  function test_DuplicateRequestRollsBackInventoryMutation() public {
    h.buy(0, 10, 100);
    h.request(0, 5, bytes32(uint256(1)), 50);
    vm.expectRevert(abi.encodeWithSelector(ClaimAccounting.DuplicateClaim.selector, bytes32(uint256(1))));
    h.request(0, 5, bytes32(uint256(1)), 50);
    assertEq(h.position(0).shares, 5);
    assertEq(h.position(0).basis, 50);
  }

  function test_BoundedActiveSetRemovesOnlyClosedClaim() public {
    h.buy(0, 65, 65);
    for (uint256 i = 1; i <= 64; ++i) {
      h.request(0, 1, bytes32(i), 1);
    }
    vm.expectRevert(ClaimAccounting.ClaimLimit.selector);
    h.request(0, 1, bytes32(uint256(65)), 1);
    h.recover(bytes32(uint256(32)), 1, 0);
    h.request(0, 1, bytes32(uint256(65)), 1);
    bytes32[] memory ids = h.active();
    assertEq(ids.length, 64);
    for (uint256 i; i < ids.length; ++i) {
      assertNotEq(ids[i], bytes32(uint256(32)));
      for (uint256 j; j < i; ++j) {
        assertNotEq(ids[i], ids[j]);
      }
    }
  }

  function test_AdapterDomainsDoNotCollide() public pure {
    assertNotEq(ClaimAccounting.key(address(1), 1), ClaimAccounting.key(address(2), 1));
  }
}
