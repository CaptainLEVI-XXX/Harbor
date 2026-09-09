// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {VaultFixture} from "test/helpers/VaultFixture.sol";
import {VaultState} from "src/vault/base/VaultState.sol";
import {WithdrawalQueue} from "src/libraries/WithdrawalQueue.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Event projections are checked against actual pending and funded entitlements.
contract VaultEventsTest is VaultFixture {
  bytes32 private constant QUEUED = keccak256("WithdrawalQueued(uint256,address,address,address,uint256)");
  bytes32 private constant FUNDED =
    keccak256("WithdrawalFunded(uint256,address,uint256,uint256,uint256,uint256,uint256)");
  bytes32 private constant WITHDRAW = keccak256("Withdraw(address,address,address,uint256,uint256)");
  bytes32 private constant MARK =
    keccak256("ValuationCommitted(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");

  function test_OperatorFundingIdentifiesPayerControllerAndReceiver() public {
    vm.prank(alice);
    vault.setOperator(bob, true);
    vm.expectEmit(true, true, true, true, address(vault));
    emit VaultState.LiquidityIssued(bob, alice, operator, 1 ether, 1 ether * 1e6);
    vm.prank(bob);
    vault.deposit(1 ether, operator, alice);
    assertEq(weth.balanceOf(bob), 99 ether);
    assertEq(weth.balanceOf(alice), 100 ether);
    assertEq(vault.balanceOf(operator), 1 ether * 1e6);
  }

  function test_FundingEventSeparatesPolicyAndMarkedVersions() public {
    uint256 shares = _deposit(alice, 10 ether);
    vm.expectEmit(true, true, true, true, address(vault));
    emit VaultState.WithdrawalQueued(0, alice, alice, alice, shares);
    _request(alice, shares);
    (uint256 policy, uint256 marked,) = vault.valuationIdentity();
    assertNotEq(marked, policy);
    vm.expectEmit(true, true, false, true, address(vault));
    emit VaultState.WithdrawalFunded(0, alice, shares, 10 ether, policy, marked, 0);
    vault.fulfillWithdrawals(1);
  }

  function test_TwoIntraBlockCheckpointsRetainDifferentComposition() public {
    uint256 shares = _deposit(alice, 10 ether);
    (uint256 policy, uint256 marked,) = vault.valuationIdentity();
    vm.recordLogs();
    book.setMark(2 ether, 3 ether, block.timestamp, true);
    vault.checkpointValuation();
    book.setMark(4 ether, 1 ether, block.timestamp, true);
    vault.checkpointValuation();
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 seen;
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].emitter != address(vault) || logs[i].topics[0] != MARK) continue;
      assertEq(
        logs[i].data,
        abi.encode(
          15 ether,
          shares,
          10 ether,
          0,
          seen == 0 ? 2 ether : 4 ether,
          seen == 0 ? 3 ether : 1 ether,
          policy,
          marked,
          block.timestamp
        )
      );
      ++seen;
    }
    assertEq(seen, 2);
  }

  function test_LiveTicketPagesSkipNoPendingObligation() public {
    uint256 shares = _deposit(alice, 40 ether);
    for (uint256 i; i < 40; ++i) {
      _request(alice, shares / 40);
    }
    (uint256 head, uint256 tail) = vault.withdrawalQueueBounds();
    assertEq(head, 0);
    assertEq(tail, 40);
    (WithdrawalQueue.Ticket[] memory tickets, uint256 next) = vault.withdrawalTickets(head, 32);
    assertEq(tickets.length, 32);
    assertEq(next, 32);
    for (uint256 i; i < tickets.length; ++i) {
      assertEq(tickets[i].controller, alice);
      assertEq(tickets[i].pending, shares / 40);
    }
    (tickets, next) = vault.withdrawalTickets(next, 32);
    assertEq(tickets.length, 8);
    assertEq(next, 40);
    (tickets, next) = vault.withdrawalTickets(next, 32);
    assertEq(tickets.length, 0);
    assertEq(next, 40);
    vault.fulfillWithdrawals(8);
    (head, tail) = vault.withdrawalQueueBounds();
    assertEq(head, 8);
    assertEq(tail, 40);
    vm.expectRevert(WithdrawalQueue.InvalidPage.selector);
    vault.withdrawalTickets(0, 1);
    vm.expectRevert(WithdrawalQueue.InvalidPage.selector);
    vault.withdrawalTickets(head, 0);
    vm.expectRevert(WithdrawalQueue.InvalidPage.selector);
    vault.withdrawalTickets(head, 33);
    vm.expectRevert(WithdrawalQueue.InvalidPage.selector);
    vault.withdrawalTickets(type(uint256).max, 1);
    (tickets, next) = vault.withdrawalTickets(head, 32);
    assertEq(tickets.length, 32);
    assertEq(next, tail);
  }

  function test_ReplayPartialFundingAndClaimMatchesControllerCredit() public {
    uint256 shares = _deposit(alice, 10 ether);
    // Explicitly synthetic noncash gain creates a cash-limited FIFO head.
    book.setMark(20 ether, 0, block.timestamp, true);
    vault.checkpointValuation();
    vm.recordLogs();
    _request(alice, shares);
    vault.fulfillWithdrawals(1);
    vm.prank(alice);
    vault.withdraw(2 ether, alice, alice);
    _assertProjection(vm.getRecordedLogs());
    (WithdrawalQueue.Ticket[] memory tickets,) = vault.withdrawalTickets(0, 32);
    assertEq(tickets.length, 1);
    assertEq(tickets[0].pending, vault.pendingRedeemRequest(0, alice));
  }

  function test_OrphanedBranchIsDiscardedBeforeReplayingCanonicalCredits() public {
    uint256 shares = _deposit(alice, 10 ether);
    uint256 checkpoint = vm.snapshotState();
    vm.recordLogs();
    _request(alice, shares);
    vault.fulfillWithdrawals(1);
    Vm.Log[] memory orphaned = vm.getRecordedLogs();
    _assertProjection(orphaned);
    assertTrue(vm.revertToState(checkpoint));
    // A read service discards the orphaned projection, then replays this branch.
    vm.recordLogs();
    _request(alice, shares / 2);
    vault.fulfillWithdrawals(1);
    _assertProjection(vm.getRecordedLogs());
    assertEq(vault.maxWithdraw(alice), 5 ether);
  }

  function test_FailedOperationDoesNotConsumeATicketOrEscrow() public {
    uint256 shares = _deposit(alice, 10 ether);
    book.setFailFinish(true);
    vm.prank(alice);
    vm.expectRevert(bytes("book finish"));
    vault.requestRedeem(shares, alice, alice);
    (uint256 head, uint256 tail) = vault.withdrawalQueueBounds();
    assertEq(head, 0);
    assertEq(tail, 0);
    assertEq(vault.balanceOf(alice), shares);
    book.setFailFinish(false);
    vm.expectEmit(true, true, true, true, address(vault));
    emit VaultState.WithdrawalQueued(0, alice, alice, alice, shares);
    _request(alice, shares);
  }

  function _assertProjection(Vm.Log[] memory logs) private view {
    uint256 pending;
    uint256 units;
    uint256 assets;
    for (uint256 i; i < logs.length; ++i) {
      Vm.Log memory log = logs[i];
      if (log.emitter != address(vault)) continue;
      if (log.topics[0] == QUEUED) {
        assertEq(address(uint160(uint256(log.topics[2]))), alice);
        (, uint256 shares) = abi.decode(log.data, (address, uint256));
        pending += shares;
      } else if (log.topics[0] == FUNDED) {
        (uint256 shares, uint256 cash,,,) = abi.decode(log.data, (uint256, uint256, uint256, uint256, uint256));
        pending -= shares;
        units += shares;
        assets += cash;
      } else if (log.topics[0] == WITHDRAW) {
        (uint256 cash, uint256 shares) = abi.decode(log.data, (uint256, uint256));
        units -= shares;
        assets -= cash;
      }
    }
    assertEq(pending, vault.pendingRedeemRequest(0, alice));
    assertEq(units, vault.claimableRedeemRequest(0, alice));
    assertEq(assets, vault.maxWithdraw(alice));
    (, uint256 reserved,,,) = vault.accountingStatus();
    assertEq(assets, reserved);
  }
}
