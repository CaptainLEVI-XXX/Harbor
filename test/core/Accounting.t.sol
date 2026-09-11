// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LPExitQueue as Queue} from "src/libraries/LPExitQueue.sol";
import {BookAccounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {RealizationLogs} from "test/base/RealizationLogs.sol";
import {RedemptionAccounting as RedemptionLedger} from "src/libraries/RedemptionAccounting.sol";
import {RedeemIntent} from "src/types/HarborTypes.sol";
import {RedemptionReference} from "test/base/RedemptionReference.sol";

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

/// @title LPExitQueueTest
/// @notice Synthetic FIFO, loss credits, aggregate rates and exact rounding tests.
contract LPExitQueueTest is Test {
  QueueHarness internal h = new QueueHarness();
  address internal constant A = address(1);
  address internal constant B = address(2);

  function test_LastReceiptCannotStrandCash() public {
    h.append(A, 1);
    h.fund(1, 10);
    vm.expectRevert(abi.encodeWithSelector(Queue.ClaimAllAssets.selector, 10));
    h.withdraw(A, 9);
    assertEq(h.withdraw(A, 10), 1);
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
    uint256 basis = state.request(route, shares, id, entitlement);
    state.protocolIds[id] = uint256(id); // Synthetic inverse ID, as populated by the issuer boundary.
    return basis;
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

  function protocolId(bytes32 key) external view returns (uint256) {
    return state.protocolIds[key];
  }

  function transferClaim(bytes32 key) external returns (uint256) {
    return ClaimAccounting.transferRight(state.claims, key);
  }
}

/// @title BookAccountingTest
/// @notice Cost conservation through synthetic partial recoveries and losses.
contract BookAccountingTest is Test {
  AccountingHarness internal h = new AccountingHarness();

  function test_ClosedPayloadClearsWithoutReusingIdentityOrLosingNonzeroRoute() public {
    bytes32 id = bytes32(uint256(7));
    h.buy(1, 2, 100);
    h.request(1, 1, id, 60);
    h.recover(id, 0, 0);
    ClaimAccounting.Claim memory c = h.claim(id);
    assertTrue(c.exists);
    assertTrue(c.closed);
    assertEq(c.route, 0);
    assertEq(c.basis, 0);
    assertEq(c.remaining, 0);
    assertEq(c.received, 0);
    assertEq(h.protocolId(id), 0);
    assertEq(h.position(1).pendingBasis, 0);
    assertEq(h.position(1).realizedLosses, 50);
    assertEq(h.position(0).realizedLosses, 0);
    vm.expectRevert(abi.encodeWithSelector(ClaimAccounting.DuplicateClaim.selector, id));
    h.request(1, 1, id, 60);
    assertEq(h.position(1).shares, 1);
    assertEq(h.position(1).basis, 50);
  }
}

contract RedemptionLedgerHarness {
  using RedemptionLedger for RedemptionLedger.State;
  RedemptionLedger.State private _state;
  RedemptionReference.State private _referenceState;

  function consume(RedeemIntent calldata i, uint256[] calldata a) external returns (bytes32) {
    return _state.consume(i, a, address(1), address(2), 3);
  }

  function consumeReference(RedeemIntent calldata i, uint256[] calldata a) external returns (bytes32) {
    return RedemptionReference.consume(_referenceState, i, a, address(1), address(2), 3);
  }

  function consumed(uint256 epoch, uint256 nonce) external view returns (bool) {
    return _state.usedNonce(epoch, nonce);
  }

  function consumedReference(uint256 epoch, uint256 nonce) external view returns (bool) {
    return _referenceState.usedNonce[epoch][nonce];
  }

  function advanceEpoch() external {
    ++_state.epoch;
    ++_referenceState.epoch;
  }

  function consumeAndFail(RedeemIntent calldata i, uint256[] calldata a) external {
    _state.consume(i, a, address(1), address(2), 3);
    revert("after nonce consumption");
  }

  function record(uint256 route, uint256 amount, uint256 minimum, uint256 limit) external {
    _state.record(route, amount, minimum, limit);
  }

  function used(uint256 route) external view returns (uint256) {
    return _state.usedToday(route);
  }

  function usage(uint256 route) external view returns (RedemptionLedger.DailyUsage memory) {
    return _state.dailyUsage[route];
  }
}

contract RedemptionAccountingTest is Test {
  RedemptionLedgerHarness private ledger;

  function setUp() public {
    vm.warp(1000);
    ledger = new RedemptionLedgerHarness();
  }

  function test_LongGapAndFailedRolloverPreserveLastSuccessfulUsage() public {
    _nonceBoundaries();
    ledger.record(0, 8, 1, 10);
    vm.warp(400 days);
    vm.expectRevert(RedemptionLedger.DailyLimit.selector);
    ledger.record(0, 11, 1, 10);
    assertEq(ledger.used(0), 0);
    assertEq(ledger.usage(0).day, 0);
    assertEq(ledger.usage(0).used, 8);
    ledger.record(0, 10, 1, 10);
    assertEq(ledger.usage(0).day, 400);
    assertEq(ledger.used(0), 10);
  }

  function _nonceBoundaries() private {
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1;
    RedeemIntent memory intent = RedeemIntent(
      block.chainid,
      address(1),
      address(ledger),
      0,
      address(2),
      1,
      1,
      1,
      1,
      3,
      0,
      0,
      block.timestamp,
      keccak256(abi.encode(amounts))
    );
    uint256[5] memory nonces = [uint256(0), 1, 255, 256, type(uint256).max];
    for (uint256 i; i < nonces.length; ++i) {
      intent.nonce = nonces[i];
      assertFalse(ledger.consumed(0, intent.nonce));
      assertFalse(ledger.consumedReference(0, intent.nonce));
      uint256 start = gasleft();
      bytes32 actual = ledger.consume(intent, amounts);
      uint256 bitmapGas = start - gasleft();
      start = gasleft();
      bytes32 expected = ledger.consumeReference(intent, amounts);
      uint256 plainGas = start - gasleft();
      assertEq(actual, expected);
      assertEq(actual, keccak256(abi.encode(intent)));
      assertTrue(ledger.consumed(0, intent.nonce));
      assertFalse(ledger.consumed(1, intent.nonce));
      if (i == 0 || i == 1 || i == 3) {
        emit log_named_uint("nonce", intent.nonce);
        emit log_named_uint("bitmap nonce gas", bitmapGas);
        emit log_named_uint("reference nonce gas", plainGas);
      }
      if (i == 1) assertLt(bitmapGas, plainGas);
      vm.expectRevert(RedemptionLedger.InvalidIntent.selector);
      ledger.consume(intent, amounts);
    }
    intent.nonce = 2;
    vm.expectRevert("after nonce consumption");
    ledger.consumeAndFail(intent, amounts);
    assertFalse(ledger.consumed(0, 2));
    ++intent.shares;
    vm.expectRevert(RedemptionLedger.InvalidIntent.selector);
    ledger.consume(intent, amounts);
    assertFalse(ledger.consumed(0, 2));
    --intent.shares;
    ledger.advanceEpoch();
    intent.epoch = 1;
    intent.nonce = 255;
    ledger.consume(intent, amounts);
    assertTrue(ledger.consumed(0, 255));
    assertTrue(ledger.consumed(1, 255));
    assertFalse(ledger.consumed(1, 256));
  }
}
