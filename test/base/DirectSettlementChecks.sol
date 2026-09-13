// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LidoViews} from "src/adapters/lido/LidoViews.sol";
import {RedemptionMarketFixture} from "test/base/RedemptionMarketFixture.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {BookState} from "src/book/base/BookState.sol";
import {Trade, RouteConfig, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingPolicy} from "src/types/PricingTypes.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockWrappedEther} from "test/base/LidoFixture.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {PricingMath} from "src/libraries/PricingMath.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {ClaimObservation, ClaimDomain} from "src/types/ClaimTypes.sol";
import {Vm} from "forge-std/Vm.sol";
import {CashPoolChecks} from "test/base/CashPoolChecks.sol";
import {BookExecution} from "src/libraries/BookExecution.sol";

/// @notice Adversarial transfer behavior on otherwise synthetic wrapped cash.
contract SettlementCallbackWeth is MockWrappedEther {
  DirectSettlementChecks private _target;

  function arm(DirectSettlementChecks target) external {
    _target = target;
  }

  function _update(address from, address to, uint256 amount) internal override {
    super._update(from, to, amount);
    if (address(_target) != address(0)) _target.onTokenTransfer();
  }
}

/// @notice Shared checks over production Harbor and unmodified official VM dispatch.
/// @dev Uses synthetic issuer state and token callbacks to exercise settlement boundaries.
contract DirectSettlementChecks is RedemptionMarketFixture {
  uint256 private _rejected;
  bool private _failCallback;
  HarborBook private _peerBook;
  uint256 private _crossPoolRejected;

  function _deployWeth() internal override returns (TokenMock) {
    return new SettlementCallbackWeth();
  }

  function onTokenTransfer() external {
    require(msg.sender == address(weth));
    assertFalse(book.isIdle());
    (bool ok, bytes memory reason) =
      address(vault).call(abi.encodeWithSignature("setOperator(address,bool)", bob, true));
    assertFalse(ok);
    assertEq(bytes4(reason), BookState.Busy.selector);
    (ok, reason) = address(book).call(abi.encodeCall(book.stopTrading, ()));
    assertFalse(ok);
    assertEq(bytes4(reason), BookState.Busy.selector);
    Trade memory nested = _trade(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether, 0);
    nested.trader = address(this);
    nested.receiver = address(this);
    (ok,) = address(executor).call(abi.encodeCall(executor.execute, (address(book), nested)));
    assertFalse(ok);
    if (address(_peerBook) != address(0)) {
      assertTrue(_peerBook.isIdle());
      assertEq(executor.vaultOf(address(_peerBook)), address(_peerBook.VAULT()));
      (ok, reason) = address(executor).call(abi.encodeCall(executor.execute, (address(_peerBook), nested)));
      assertFalse(ok);
      assertEq(bytes4(reason), bytes4(keccak256("Reentrancy()")));
      ++_crossPoolRejected;
    }
    // A second funding callback cannot spend the trader's allowance, even if a
    // token callback can invoke a call impersonating the router in this test.
    bytes32 nestedHash = book.strategyHash(0);
    vm.prank(address(router));
    (ok, reason) = address(executor)
      .call(
        abi.encodeCall(
          executor.preTransferInCallback,
          (
            address(vault),
            address(executor),
            nested.tokenIn,
            nested.tokenOut,
            1,
            1,
            nestedHash,
            abi.encode(address(book), nested)
          )
        )
      );
    assertFalse(ok);
    assertEq(bytes4(reason), HarborExecutor.InvalidCallback.selector);
    _rejected += 4;
    require(!_failCallback, "callback failure");
  }

  /// @notice Same workload as the recorded baseline: previewed/cooled native trades.
  /// @dev Setup, preview and transaction intrinsic gas are excluded. Replays use
  /// identical pre-trade state and cool every account touched by the warm trade.
  function measure() external returns (uint256[4] memory gasUsed, uint256[4] memory coldGas) {
    setUp();
    uint256[4] memory sizes = [uint256(0), 1, 8, 64];
    uint256 held;
    uint256[64] memory issuerIds;
    for (uint256 i; i < sizes.length; ++i) {
      while (held < sizes[i]) {
        (uint256 route, uint256 issuerId,) = _externalMarket(0.001 ether);
        issuerIds[held] = issuerId;
        _tradeClaim(route, Side.BUY_BASE, AmountMode.EXACT_IN);
        ++held;
      }
      vault.checkpointValuation();
      Trade memory t = _trade(1, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether, 0);
      executor.quote(address(book), t);
      uint256 cash = weth.balanceOf(address(vault));
      uint256 state = vm.snapshotState();
      vm.startStateDiffRecording();
      vm.prank(trader);
      uint256 beforeGas = gasleft();
      executor.execute(address(book), t);
      gasUsed[i] = beforeGas - gasleft();
      Vm.AccountAccess[] memory accesses = _assertKernelCalls();
      vm.revertToState(state);
      for (uint256 j; j < accesses.length; ++j) {
        vm.cool(accesses[j].account);
      }
      vm.startStateDiffRecording();
      vm.prank(trader);
      beforeGas = gasleft();
      executor.execute(address(book), t);
      coldGas[i] = beforeGas - gasleft();
      _assertKernelCalls();
      assertEq(weth.balanceOf(address(vault)), cash - 0.99 ether);
      assertEq(book.getPosition(1).shares, (i + 1) * 1 ether);
      assertTrue(book.isIdle());
    }
    for (uint256 i; i < 32; ++i) {
      queue.setFinalized(issuerIds[i], 0.0009 ether);
      if (i < 16) {
        address receipt = factory.receiptOf(address(adapter), adapter.nativeClaimId(issuerIds[i]));
        IHarborClaim(receipt).recover(abi.encode(uint256(1)));
      }
    }
    vm.startStateDiffRecording();
    uint256 beforeNavGas = gasleft();
    (, uint256 claimValue,,, bool valid) = book.valuation();
    emit log_named_uint("mixed 64 NAV gas", beforeNavGas - gasleft());
    assertTrue(valid);
    assertEq(claimValue, 32 * 0.0009 ether + 32 * 0.0012 ether);
    Vm.AccountAccess[] memory navAccesses = vm.stopAndReturnStateDiff();
    uint256 statusCalls;
    uint256 cashCalls;
    for (uint256 i; i < navAccesses.length; ++i) {
      if (navAccesses[i].account != address(queue)) continue;
      if (bytes4(navAccesses[i].data) == bytes4(keccak256("getWithdrawalStatus(uint256[])"))) ++statusCalls;
      if (bytes4(navAccesses[i].data) == bytes4(keccak256("getClaimableEther(uint256[],uint256[])"))) ++cashCalls;
    }
    assertEq(statusCalls, 1);
    assertEq(cashCalls, 1);
    _assertBatchOrderAndUniqueness(issuerIds);
  }

  /// @dev Adversarial ordering at the 64-ID boundary: gathering/duplicate detection
  /// must not sort the caller's outputs or confuse finalized cash with pending marks.
  function _assertBatchOrderAndUniqueness(uint256[64] memory issuerIds) private {
    bytes32[] memory ids = new bytes32[](64);
    for (uint256 i; i < 64; ++i) {
      ids[i] = adapter.nativeClaimId(issuerIds[(i * 17) % 64]); // 17 is coprime to 64.
    }
    (, ClaimObservation[] memory observations) = adapter.observePortfolio(address(bases[0]), 0, ids);
    assertEq(observations.length, 64);
    for (uint256 i; i < 64; ++i) {
      uint256 original = (i * 17) % 64;
      ClaimObservation memory o = observations[i];
      assertEq(uint256(o.domain), uint256(ClaimDomain.TOKENIZED));
      assertEq(
        uint256(o.status),
        uint256(
          original < 16
            ? IHarborClaim.Status.CASH_READY
            : original < 32 ? IHarborClaim.Status.FINALIZED : IHarborClaim.Status.PENDING
        )
      );
      assertEq(o.entitlement, 0.0012 ether);
      assertEq(o.mark, original < 32 ? 0.0009 ether : 0.0012 ether);
      assertEq(o.cash, original < 16 ? 0.0009 ether : 0);
      assertTrue(o.valid);
    }
    ids[63] = ids[0]; // Nonadjacent duplicate, not merely an already sorted pair.
    vm.expectRevert(LidoViews.InvalidObservation.selector);
    adapter.observePortfolio(address(bases[0]), 0, ids);
    ids[63] = bytes32(0); // Unique but unknown must still fail before issuer reads.
    vm.expectRevert(LidoViews.InvalidObservation.selector);
    adapter.observePortfolio(address(bases[0]), 0, ids);
  }

  function _assertKernelCalls() private returns (Vm.AccountAccess[] memory accesses) {
    accesses = vm.stopAndReturnStateDiff();
    uint256 calls;
    uint256 extensions;
    uint256 fundingCallbacks;
    bool extensionEntered;
    for (uint256 i; i < accesses.length; ++i) {
      if (accesses[i].account == address(book) && bytes4(accesses[i].data) == book.extruction.selector) {
        assertEq(accesses[i].accessor, address(router));
        extensionEntered = true;
        ++extensions;
      }
      if (
        accesses[i].account == address(PricingMath) && bytes4(accesses[i].data) == PricingMath.quoteConfigured.selector
      ) {
        assertTrue(extensionEntered, "pricing occurred before VM extension");
        ++calls;
      }
      if (
        accesses[i].account == address(executor) && bytes4(accesses[i].data) == executor.preTransferInCallback.selector
      ) {
        assertEq(accesses[i].accessor, address(router));
        assertEq(calls, 1, "funding preceded the VM price");
        ++fundingCallbacks;
      }
      assertFalse(
        accesses[i].account == address(PricingMath) && bytes4(accesses[i].data) == PricingMath.quote.selector,
        "execution used preview fee arithmetic"
      );
    }
    assertEq(calls, 1, "one core pricing calculation");
    assertEq(extensions, 1, "one official Extruction invocation");
    assertEq(fundingCallbacks, 1, "one authenticated funding callback");
  }

  function checkModesAndReceipts() external {
    setUp();
    for (uint256 i; i < 4; ++i) {
      bool buy = i < 2;
      bool exactIn = i % 2 == 0;
      uint256 quantity = 1 ether + 17;
      uint256 cash = buy ? quantity * 99 / 100 : (quantity * 101 + 99) / 100;
      uint256 fee = buy ? cash * 10 / 10000 : cash * 10 / 9990;
      uint256 customerCash = buy ? cash - fee : cash + fee;
      if (buy && !exactIn) {
        cash = customerCash + customerCash * 10 / 9990;
        quantity = (cash * 100 + 98) / 99;
        fee = cash - customerCash;
      } else if (!buy && exactIn) {
        fee = customerCash * 10 / 10000;
        cash = customerCash - fee;
        quantity = cash * 100 / 101;
      }
      Trade memory t = _trade(
        1,
        buy ? Side.BUY_BASE : Side.SELL_BASE,
        exactIn ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT,
        buy ? quantity : customerCash,
        buy ? customerCash : quantity
      );
      _assertSwap(t, buy ? quantity : customerCash, buy ? customerCash : quantity, cash, fee);
    }
    (uint256 route,, address receipt) = _externalMarket(1 ether);
    for (uint256 i; i < 4; ++i) {
      bool buy = i % 2 == 0;
      AmountMode mode = i < 2 ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT;
      uint256 cash = buy ? 1.164 ether : 1.176 ether;
      uint256 fee = buy ? cash * 10 / 10000 : cash * 10 / 9990;
      uint256 customerCash = buy ? cash - fee : cash + fee;
      Trade memory t =
        _trade(route, buy ? Side.BUY_BASE : Side.SELL_BASE, mode, buy ? 1 : customerCash, buy ? customerCash : 1);
      vm.prank(trader);
      IERC20(receipt).approve(address(executor), 1);
      _assertSwap(t, buy ? 1 : customerCash, buy ? customerCash : 1, cash, fee);
      assertEq(IERC20(receipt).balanceOf(address(vault)), buy ? 1 : 0);
    }
    // Canonical bid 999 maps to net 999; upstream's inverse initially returns 1000.
    (route,, receipt) = _externalMarket(859);
    Trade memory dust = _trade(route, Side.BUY_BASE, AmountMode.EXACT_OUT, 1, 999);
    _assertSwap(dust, 1, 999, 999, 0);
    dust.amountSpecified = 998;
    vm.expectRevert();
    executor.quoteSwap(address(book), dust);
  }

  function checkRollbackAndCallBinding() external {
    setUp();
    Trade memory t = _trade(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether, 0);
    // The shared ABI boundary is not an alternative, unauthenticated quote path.
    vm.expectRevert(BookState.Unauthorized.selector);
    book.priceTrade(t, true, t.amountSpecified);
    uint256 cash = weth.balanceOf(address(vault));
    uint256 base = bases[0].balanceOf(trader);
    uint256 version = book.getPosition(0).version;
    (uint256 allocation,) =
      aqua.safeBalances(address(vault), address(router), book.strategyHash(0), address(weth), address(bases[0]));
    vm.mockCallRevert(address(weth), abi.encodeCall(IERC20.transfer, (trader, 1.186812 ether)), "late payout");
    vm.expectRevert();
    vm.prank(trader);
    executor.execute(address(book), t);
    assertEq(weth.balanceOf(address(vault)), cash);
    assertEq(bases[0].balanceOf(trader), base);
    assertEq(book.getPosition(0).version, version);
    (uint256 afterAllocation,) =
      aqua.safeBalances(address(vault), address(router), book.strategyHash(0), address(weth), address(bases[0]));
    assertEq(afterAllocation, allocation);
    assertTrue(book.isIdle());
    vm.clearMockedCalls();

    bytes32 callbackHash = book.strategyHash(0);
    // Fixed linked code is not an independently callable settlement authority.
    BookExecution.Hook memory fake =
      BookExecution.Hook(address(vault), address(executor), t.tokenIn, t.tokenOut, 1, 1, callbackHash);
    (bool directlyCalled,) = address(BookExecution).call(abi.encodeWithSelector(BookExecution.preOutput.selector, fake));
    assertFalse(directlyCalled);
    vm.expectRevert(BookState.InvalidCallback.selector);
    book.postTransferIn(fake.maker, fake.taker, fake.tokenIn, fake.tokenOut, 1, 1, 0, callbackHash, "", "");
    vm.prank(address(router));
    vm.expectRevert(BookState.InvalidCallback.selector);
    book.postTransferIn(fake.maker, fake.taker, fake.tokenIn, fake.tokenOut, 1, 1, 0, callbackHash, "", "");
    vm.prank(address(router));
    vm.expectRevert(HarborExecutor.InvalidCallback.selector);
    executor.preTransferInCallback(
      address(vault), address(executor), t.tokenIn, t.tokenOut, 1, 1, callbackHash, abi.encode(address(book), t)
    );
    vm.expectRevert(HarborExecutor.UnauthorizedTrader.selector);
    executor.execute(address(book), t);
    SettlementCallbackWeth(address(weth)).arm(this);
    _failCallback = true;
    vm.expectRevert();
    vm.prank(trader);
    executor.execute(address(book), t);
    assertEq(_rejected, 0);
    assertEq(weth.balanceOf(address(vault)), cash);
    assertEq(book.getPosition(0).version, version);
    assertTrue(book.isIdle());
    _failCallback = false;
    t.receiver = bob;
    uint256 beforeBob = weth.balanceOf(bob);
    vm.prank(trader);
    executor.execute(address(book), t);
    vm.prank(trader);
    executor.execute(address(book), t);
    assertEq(weth.balanceOf(bob) - beforeBob, 2 * 1.186812 ether);
    assertEq(_rejected, 24); // Three ASSET transfers, four attacks, two executions.
    assertEq(bases[0].allowance(address(executor), address(router)), 0);
  }

  function checkTwoPoolsAndZeroFee() external {
    setUp();
    HarborBook firstBook = book;
    HarborVault firstVault = vault;
    HarborExecutor firstExecutor = executor;
    uint256 firstCash = weth.balanceOf(address(firstVault));
    uint256 firstFace = firstBook.faceExposure();
    bytes32 firstHash = firstBook.strategyHash(0);
    // Same Aqua, Router, ERC-20 pair, trader and numeric route. Different makers and Books.
    uint64 nonce = vm.getNonce(address(this));
    HarborBook.Config memory c = deploymentConfig;
    c.vault = vm.computeCreateAddress(address(this), nonce + 1);
    c.executor = address(executor);
    c.feeBps = 0;
    RouteConfig[] memory routes = new RouteConfig[](1);
    routes[0] = firstBook.route(0);
    routes[0].adapter = vm.computeCreateAddress(address(this), nonce + 2);
    book = new HarborBook(c, routes);
    vault = new HarborVault(address(weth), address(book), 60, 1e12, 1e6);
    executor.registerPool(address(book));
    LidoAdapter secondAdapter = new LidoAdapter(
      address(book),
      address(vault),
      address(bases[0]),
      address(weth),
      address(queue),
      LidoViews.Config(address(factory), address(this), address(this), 60, 1 days)
    );
    assertEq(address(secondAdapter), routes[0].adapter);
    secondAdapter.publish(1e18, 1e18, vm.getBlockTimestamp(), vm.getBlockTimestamp() + 60, 1);
    vault.checkpointValuation();
    weth.mint(alice, 5 ether);
    vm.startPrank(alice);
    weth.approve(address(vault), 5 ether);
    vault.deposit(5 ether, alice);
    vm.stopPrank();
    vault.refreshStrategy(0);
    book.configurePricing(0, PricingPolicy(0.95e18, 1e18, 0.01e18, 0.01e18, 0, 0));
    _publish(0, 1e18);
    Trade memory t = _trade(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether, 0);
    assertNotEq(firstHash, book.strategyHash(0));
    vm.prank(trader);
    bases[0].approve(address(executor), type(uint256).max);
    uint256 fees = weth.balanceOf(feeRecipient);
    _assertSwap(t, 1 ether, 1.188 ether, 1.188 ether, 0);
    assertEq(weth.balanceOf(feeRecipient), fees);
    assertEq(weth.balanceOf(address(firstVault)), firstCash);
    assertEq(firstBook.faceExposure(), firstFace);
    assertEq(firstBook.strategyHash(0), firstHash);
    assertEq(firstBook.getPosition(0).shares, 4 ether);
    assertEq(book.getPosition(0).shares, 1 ether);
    assertTrue(firstBook.isIdle());
    assertTrue(book.isIdle());
    vault.checkpointValuation();
    vm.prank(alice);
    vault.requestRedeem(0.5 ether * 1e6, alice, alice);
    vault.fulfillWithdrawals(1);
    HarborVault secondVault = vault;
    HarborBook secondBook = book;
    uint256 secondCredit = secondVault.maxWithdraw(alice);
    uint256 secondCash = weth.balanceOf(address(secondVault));
    assertGt(secondCredit, 0);
    // Both pools remain usable sequentially through the same Router.
    book = firstBook;
    vault = firstVault;
    executor = firstExecutor;
    _peerBook = secondBook;
    SettlementCallbackWeth(address(weth)).arm(this);
    _buy(0, 1 ether);
    SettlementCallbackWeth(address(weth)).arm(DirectSettlementChecks(address(0)));
    assertEq(_crossPoolRejected, 3); // Fee, pool payout and customer payout.
    assertEq(firstBook.getPosition(0).shares, 5 ether);
    assertEq(secondVault.maxWithdraw(alice), secondCredit);
    assertEq(weth.balanceOf(address(secondVault)), secondCash);
    new CashPoolChecks().run(executor, firstBook);
    assertEq(secondVault.maxWithdraw(alice), secondCredit);
    assertEq(weth.balanceOf(address(secondVault)), secondCash);
  }

  function _assertSwap(Trade memory t, uint256 input, uint256 output, uint256 cash, uint256 fee) private {
    bool buy = t.side == Side.BUY_BASE;
    uint256 beforeCash = weth.balanceOf(address(vault));
    uint256 beforeInput = IERC20(t.tokenIn).balanceOf(t.trader);
    uint256 beforeOutput = IERC20(t.tokenOut).balanceOf(t.receiver);
    uint256 beforeFee = weth.balanceOf(feeRecipient);
    (uint256 quotedIn, uint256 quotedOut, bytes32 hash) = executor.quoteSwap(address(book), t);
    assertEq(quotedIn, input);
    assertEq(quotedOut, output);
    assertEq(hash, book.strategyHash(t.route));
    vm.startStateDiffRecording();
    vm.prank(trader);
    executor.execute(address(book), t);
    _assertKernelCalls();
    assertEq(IERC20(t.tokenIn).balanceOf(t.trader), beforeInput - input);
    assertEq(IERC20(t.tokenOut).balanceOf(t.receiver), beforeOutput + output);
    assertEq(weth.balanceOf(address(vault)), buy ? beforeCash - cash : beforeCash + cash);
    assertEq(weth.balanceOf(feeRecipient), beforeFee + fee);
    assertEq(IERC20(t.tokenIn).balanceOf(address(router)), 0);
    assertEq(IERC20(t.tokenOut).balanceOf(address(router)), 0);
    assertEq(IERC20(t.tokenIn).allowance(address(executor), address(router)), 0);
    assertEq(weth.balanceOf(address(executor)), 0);
    assertTrue(book.isIdle());
  }
}
