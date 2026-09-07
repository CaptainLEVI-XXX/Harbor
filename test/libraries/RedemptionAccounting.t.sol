// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RedemptionAccounting as Ledger} from "src/libraries/RedemptionAccounting.sol";
import {RedeemIntent} from "src/types/HarborTypes.sol";

contract RedemptionLedgerHarness {
  using Ledger for Ledger.State;
  Ledger.State private _state;

  function consume(RedeemIntent calldata i, uint256[] calldata a) external returns (bytes32) {
    return _state.consume(i, a, address(1), address(2), 3);
  }

  function record(uint256 route, uint256 amount, uint256 minimum, uint256 limit) external {
    _state.record(route, amount, minimum, limit);
  }

  function used(uint256 day) external view returns (uint256) {
    return _state.dailyRequested[0][day];
  }
}

contract RedemptionAccountingTest is Test {
  RedemptionLedgerHarness private ledger;

  function setUp() public {
    vm.warp(1000);
    ledger = new RedemptionLedgerHarness();
  }

  function test_DailyBoundaryAndIndependentRoutes() public {
    ledger.record(0, 6, 1, 10);
    ledger.record(0, 4, 1, 10);
    vm.expectRevert(Ledger.DailyLimit.selector);
    ledger.record(0, 1, 1, 10);
    ledger.record(1, 10, 1, 10);
    assertEq(ledger.used(0), 10);
    vm.warp(1 days);
    ledger.record(0, 10, 1, 10);
    assertEq(ledger.used(0), 10);
    assertEq(ledger.used(1), 10);
  }

  function testFuzz_DailyRequestsNeverExceedLimit(uint128 a, uint128 b, uint128 limit) public {
    a = uint128(bound(a, 1, type(uint128).max));
    b = uint128(bound(b, 1, type(uint128).max));
    uint256 sum = uint256(a) + b;
    if (a > limit) {
      vm.expectRevert(Ledger.DailyLimit.selector);
      ledger.record(0, a, 1, limit);
      assertEq(ledger.used(0), 0);
    } else {
      ledger.record(0, a, 1, limit);
      if (sum > limit) vm.expectRevert(Ledger.DailyLimit.selector);
      ledger.record(0, b, 1, limit);
      assertEq(ledger.used(0), sum > limit ? a : sum);
    }
  }

  function test_ExactSplitDeadlineAndNonceBinding() public {
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 7;
    RedeemIntent memory i = RedeemIntent(
      block.chainid,
      address(1),
      address(ledger),
      0,
      address(2),
      1,
      7,
      7,
      1,
      3,
      0,
      1,
      1060,
      keccak256(abi.encode(amounts))
    );
    i.splitsHash = 0;
    vm.expectRevert(Ledger.InvalidIntent.selector);
    ledger.consume(i, amounts);
    i.splitsHash = keccak256(abi.encode(amounts));
    i.deadline = block.timestamp + 1 days + 1;
    vm.expectRevert(Ledger.InvalidIntent.selector);
    ledger.consume(i, amounts);
    i.deadline = block.timestamp;
    assertEq(ledger.consume(i, amounts), keccak256(abi.encode(i)));
    vm.expectRevert(Ledger.InvalidIntent.selector);
    ledger.consume(i, amounts);
    i.nonce = 2;
    vm.warp(1001);
    vm.expectRevert(Ledger.InvalidIntent.selector);
    ledger.consume(i, amounts);
  }
}
