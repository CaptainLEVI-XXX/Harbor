// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedemptionMarketFixture} from "test/claims/RedemptionMarket.t.sol";
import {RealizationLogs} from "test/helpers/RealizationLogs.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

contract ReceiptEventsTest is RedemptionMarketFixture {
  function test_ExportEmitsPreservedBasisButNoRealizedRevenue() public {
    uint256 id = _request(1 ether);
    uint256 basis = book.getClaim(address(adapter), id).basis;
    vm.recordLogs();
    uint256 route = book.exportClaim(0, id, address(factory));
    Vm.Log[] memory logs = vm.getRecordedLogs();
    (uint256 gains, uint256 losses, uint256 realizations) = RealizationLogs.totals(logs, address(book), 0);
    assertEq(gains + losses + realizations, 0);
    uint256 exports;
    uint256 acquisitions;
    for (uint256 i; i < logs.length; ++i) {
      Vm.Log memory log = logs[i];
      if (log.emitter != address(book)) continue;
      if (log.topics[0] == keccak256("NativeClaimExported(uint256,uint256,uint256,address,uint256)")) {
        assertEq(uint256(log.topics[1]), 0);
        assertEq(uint256(log.topics[2]), id);
        assertEq(uint256(log.topics[3]), route);
        assertEq(log.data, abi.encode(book.route(route).base, basis));
        ++exports;
      } else if (log.topics[0] == keccak256("ReceiptAcquired(uint256,uint256,uint256,bool)")) {
        assertEq(uint256(log.topics[1]), route);
        assertEq(uint256(log.topics[2]), 1);
        assertEq(log.data, abi.encode(basis, true));
        ++acquisitions;
      }
    }
    assertEq(exports, 1);
    assertEq(acquisitions, 1);
    assertTrue(book.getClaim(address(adapter), id).closed);
    assertEq(book.claimTotals(0).basis, basis);
    assertEq(book.claimTotals(0).purchases, 0);
    vm.expectRevert();
    book.exportClaim(0, id, address(factory));
  }

  function test_ReceiptVersionsAndResultsSurviveSaleReacquisitionAndTotalLoss() public {
    (uint256 route, uint256 id, address receipt) = _externalMarket(1 ether);
    uint256 cost = 1.164 ether;
    _tradeWithEvent(route, Side.BUY_BASE, AmountMode.EXACT_IN, 1, cost);
    _tradeWithEvent(route, Side.SELL_BASE, AmountMode.EXACT_OUT, 2, cost);
    vm.prank(trader);
    IERC20(receipt).approve(address(executor), 1);
    _tradeWithEvent(route, Side.BUY_BASE, AmountMode.EXACT_OUT, 3, cost);
    queue.setFinalized(id, 0);
    vm.expectEmit(true, true, false, true, address(book));
    emit ClaimMarkets.ReceiptDisposed(route, 4, cost, 0, true);
    book.recoverClaim(route, 1);
    assertEq(book.claimTotals(0).purchases, cost * 2);
    assertEq(book.claimTotals(0).losses, cost);
    assertEq(book.getPosition(route).realizedLosses, 0);
    assertEq(book.getPosition(route).version, 4);
  }

  function _tradeWithEvent(uint256 route, Side side, AmountMode mode, uint256 version, uint256 cost) private {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) = _claimQuote(route, side, mode);
    // Construct the quote before arming the expectation for the next external call.
    vm.expectEmit(true, true, false, true, address(book));
    if (side == Side.BUY_BASE) emit ClaimMarkets.ReceiptAcquired(route, version, cost, false);
    else emit ClaimMarkets.ReceiptDisposed(route, version, cost, 1.176 ether, false);
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    vault.checkpointValuation();
  }

  function test_PublicationEmitsFactoryVersionAndQuoteEpoch() public {
    (uint256 route,,) = _externalMarket(1 ether);
    uint256 version = book.strategyVersion(route) + 1;
    uint256 epoch = book.quoteEpoch() + 1;
    vm.recordLogs();
    vault.refreshStrategy(route);
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 published;
    for (uint256 i; i < logs.length; ++i) {
      Vm.Log memory log = logs[i];
      if (
        log.emitter != address(book)
          || log.topics[0] != keccak256("StrategyPublished(uint256,bytes32,uint256,uint256,uint256)")
      ) continue;
      assertEq(uint256(log.topics[1]), route);
      assertEq(log.topics[2], book.strategyHash(route));
      assertEq(log.data, abi.encode(version, factory.version(), epoch));
      ++published;
    }
    assertEq(published, 1);
  }
}
