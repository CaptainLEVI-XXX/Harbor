// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {BookState} from "src/book/base/BookState.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {TradingFixture} from "test/base/TradingFixture.sol";
import {MockCREForwarder} from "test/core/HarborPolicyReceiver.t.sol";
import {HarborPolicyReceiver as Receiver} from "src/HarborPolicyReceiver.sol";
import {IHarborPolicyReceiver} from "src/interfaces/IHarborPolicyReceiver.sol";
import {RealizationLogs} from "test/base/RealizationLogs.sol";

/// @title FourModeTradingTest
/// @notice Official settlement through the real Book, Executor and pooled vault.
contract FourModeTradingTest is TradingFixture {
  function test_TwoRoutesCannotSpendSameCash() public {
    _buy(0, 16 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(1, Side.BUY_BASE, AmountMode.EXACT_IN, 16 ether);
    vm.expectRevert(BookState.CapacityExceeded.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertEq(book.getPosition(1).shares, 0);
  }

  function test_SignerAndPolicyAreIndependentlyRequired() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    _setApproval(executor.fillDigest(t, f), false);
    vm.expectRevert(BookState.PolicyNotApproved.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    _setApproval(executor.fillDigest(t, f), true);
    sig[0] = bytes1(uint8(sig[0]) ^ 1);
    vm.expectRevert(BookState.InvalidSignature.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
  }

  function test_LateFeeFailureRollsBackEverything() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    uint256 version = book.portfolioVersion();
    vm.mockCallRevert(
      address(weth), abi.encodeWithSignature("transfer(address,uint256)", feeRecipient, f.fee), "fee payout failed"
    );
    vm.expectRevert();
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertFalse(book.usedQuoteNonce(f.epoch, f.nonce));
    assertFalse(book.usedTraderNonce(trader, t.nonce));
    assertEq(book.portfolioVersion(), version);
    assertEq(book.getPosition(0).shares, 0);
    assertEq(weth.balanceOf(address(vault)), 20 ether);
    assertEq(bases[0].balanceOf(trader), 100 ether);
    assertEq(bases[0].allowance(address(executor), address(router)), 0);
    vm.clearMockedCalls();
    vm.prank(trader);
    executor.execute(t, f, sig, order);
  }

  function test_OldQuoteFailsAfterPortfolioChange() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    _buy(1, 1 ether);
    vm.expectRevert(BookState.InvalidQuote.selector);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
  }

  function test_OnlyTraderMayExecute() public {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether);
    vm.expectRevert(HarborExecutor.UnauthorizedTrader.selector);
    executor.execute(t, f, sig, order);
  }
}

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

  function _execute(Side side, AmountMode mode, uint256 amount) private {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) = _quote(0, side, mode, amount);
    bytes32 digest = executor.fillDigest(t, f);
    assertTrue(receiver.isApproved(digest));
    executor.quoteFill(t, f, sig, order);
    bool buy = side == Side.BUY_BASE;
    // Independent fixture prices: buy at 0.99, sell at 1.01; 10 bps WETH fee.
    uint256 cash = amount * (buy ? 99 : 101) / 100;
    uint256 traderCash = buy ? cash * 9990 / 10000 : (cash * 10000 + 9989) / 9990;
    uint256 fee = buy ? cash - traderCash : traderCash - cash;
    uint256 beforeCash = weth.balanceOf(address(vault));
    uint256 beforeTrader = weth.balanceOf(trader);
    uint256 beforeBase = bases[0].balanceOf(trader);
    uint256 beforeFee = weth.balanceOf(feeRecipient);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertEq(weth.balanceOf(address(vault)), buy ? beforeCash - cash : beforeCash + cash);
    assertEq(weth.balanceOf(trader), buy ? beforeTrader + traderCash : beforeTrader - traderCash);
    assertEq(bases[0].balanceOf(trader), buy ? beforeBase - amount : beforeBase + amount);
    assertEq(weth.balanceOf(feeRecipient), beforeFee + fee);
    assertEq(weth.balanceOf(address(executor)), 0);
    assertEq(bases[0].balanceOf(address(executor)), 0);
    assertTrue(book.usedQuoteNonce(f.epoch, f.nonce));
    // Permit storage is not consumption; Book's persistent nonce prevents reuse.
    assertTrue(receiver.isApproved(digest));
    vm.prank(trader);
    vm.expectRevert(BookState.InvalidQuote.selector);
    executor.execute(t, f, sig, order);
    vault.checkpointValuation();
  }
}
