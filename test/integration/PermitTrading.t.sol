// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TradingFixture} from "test/helpers/TradingFixture.sol";
import {MockCREForwarder} from "test/chainlink/HarborPolicyReceiver.t.sol";
import {HarborPolicyReceiver as Receiver} from "src/HarborPolicyReceiver.sol";
import {IHarborPolicyReceiver} from "src/interfaces/IHarborPolicyReceiver.sol";
import {BookState} from "src/book/base/BookState.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {RealizationLogs} from "test/helpers/RealizationLogs.sol";

/// @notice Real receiver, official Aqua and Harbor's derived router with simulated reports.
/// @dev No DON signature or confidential-execution claim is made by this fixture.
contract PermitTradingTest is TradingFixture {
  Receiver private receiver;
  MockCREForwarder private forwarder;
  Receiver.Config private receiverConfig;

  function _deployPolicy() internal override returns (IHarborPolicyReceiver) {
    uint64 nonce = vm.getNonce(address(this));
    forwarder = new MockCREForwarder();
    receiverConfig = Receiver.Config(
      address(forwarder),
      vm.computeCreateAddress(address(this), nonce + 2),
      vm.computeCreateAddress(address(this), nonce + 3),
      address(this),
      address(this),
      keccak256("synthetic-workflow"),
      bytes10(keccak256("synthetic-name")),
      address(42),
      5009297550715157269,
      1,
      keccak256("public-model"),
      60
    );
    receiver = new Receiver(receiverConfig);
    return receiver;
  }

  function _approveFill(Trade memory, FillTerms memory f, bytes32 digest) internal override {
    Receiver.Report memory r = Receiver.Report(
      1,
      block.chainid,
      receiverConfig.chainSelector,
      address(receiver),
      address(book),
      address(vault),
      digest,
      receiver.authorizationEpoch(),
      f.nonce,
      1,
      receiverConfig.modelHash,
      f.observationHash,
      f.observedAt,
      f.validUntil,
      1
    );
    forwarder.deliver(
      receiver,
      abi.encodePacked(
        receiverConfig.workflowId, receiverConfig.workflowName, receiverConfig.workflowOwner, bytes2(0x0000)
      ),
      abi.encode(r)
    );
  }

  function test_AuthenticatedPermitSettlesAllFourModes() public {
    vm.recordLogs();
    _execute(Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    _execute(Side.BUY_BASE, AmountMode.EXACT_OUT, 1 ether);
    _execute(Side.SELL_BASE, AmountMode.EXACT_IN, 1 ether);
    _execute(Side.SELL_BASE, AmountMode.EXACT_OUT, 1 ether);
    assertEq(book.getPosition(0).shares, 0);
    (uint256 gains,, uint256 count) = RealizationLogs.totals(vm.getRecordedLogs(), address(book), 0);
    assertGt(gains, 0);
    assertEq(count, 2);
  }

  function test_PermitCannotOverridePendingLPWithdrawalPriority() public {
    uint256 shares = vault.balanceOf(alice);
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    assertTrue(receiver.isApproved(executor.fillDigest(t, f)));
    vm.prank(trader);
    vm.expectRevert(BookState.CapacityExceeded.selector);
    executor.execute(t, f, sig, order);
  }

  function test_CancelledPermitsDoNotPreventFundedLPClaims() public {
    uint256 shares = vault.balanceOf(alice);
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    vault.fulfillWithdrawals(1);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    receiver.cancelPermits();
    vm.prank(trader);
    vm.expectRevert(BookState.PolicyNotApproved.selector);
    executor.execute(t, f, sig, order);
    uint256 credit = vault.maxWithdraw(alice);
    uint256 beforeBalance = weth.balanceOf(alice);
    vm.prank(alice);
    vault.withdraw(credit, alice, alice);
    assertEq(weth.balanceOf(alice), beforeBalance + credit);
  }

  function test_ChangedReceiverNeedsIndependentNewPermit() public {
    (Trade memory t, FillTerms memory f,, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    t.receiver = address(0x5555);
    bytes32 digest = executor.fillDigest(t, f);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(QUOTE_TEST_KEY, digest);
    assertFalse(receiver.isApproved(digest));
    vm.prank(trader);
    vm.expectRevert(BookState.PolicyNotApproved.selector);
    executor.execute(t, f, abi.encodePacked(r, s, v), order);
  }

  function test_ReadOnlyVerifierCannotChooseBookSigner() public {
    (Trade memory t, FillTerms memory f,, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    bytes32 digest = executor.fillDigest(t, f);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(99, digest);
    bytes memory wrongSignature = abi.encodePacked(r, s, v);
    assertEq(executor.validateQuote(t, f, wrongSignature, vm.addr(99)), digest);
    vm.prank(trader);
    vm.expectRevert(BookState.InvalidSignature.selector);
    executor.execute(t, f, wrongSignature, order);
    assertEq(book.getPosition(0).shares, 0);
  }

  function _execute(Side side, AmountMode mode, uint256 amount) private {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) = _quote(0, side, mode, amount);
    bytes32 digest = executor.fillDigest(t, f);
    assertTrue(receiver.isApproved(digest));
    executor.quoteFill(t, f, sig, order);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertTrue(book.usedQuoteNonce(f.epoch, f.nonce));
    // Permit storage is not consumption; Book's persistent nonce prevents reuse.
    assertTrue(receiver.isApproved(digest));
    vm.prank(trader);
    vm.expectRevert(BookState.InvalidQuote.selector);
    executor.execute(t, f, sig, order);
    vault.checkpointValuation();
  }
}
