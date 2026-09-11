// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {LidoViews} from "src/adapters/lido/LidoViews.sol";

import {HoodiFork} from "test/base/HoodiFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {HarborClaimReceipt} from "src/claims/HarborClaimReceipt.sol";
import {ILidoWithdrawalQueue as Queue, IWstETHConversion} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {Trade, FillAmounts, RouteConfig, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingParameters, PricingCurve} from "src/types/PricingTypes.sol";
import {ClaimImport, CollateralKind} from "src/types/ClaimTypes.sol";

/// @notice Four-mode trading with existing Hoodi issuer, WETH, Aqua and Router deployments.
/// @dev Real Harbor pricing, valuation and pooled execution with illustrative parameters; no token storage edits.
contract RedemptionMarketForkTest is HoodiFork {
  function test_ForkFourReceiptModesAndLpWithdrawal() public {
    (HarborBook book, HarborVault vault, HarborExecutor executor, LidoAdapter marks) = _deployHarbor();
    HarborClaimFactory factory = HarborClaimFactory(marks.FACTORY());
    factory.schedule(address(marks));
    vm.warp(vm.getBlockTimestamp() + 1 days);
    factory.activate(address(marks));
    book.scheduleClaimFactory(address(factory), 0, 0.97e18, 0.98e18);
    vm.warp(vm.getBlockTimestamp() + 1 days); // Admission delay, not issuer finalization.
    book.activateClaimFactory(address(factory), address(marks));
    uint256 time = vm.getBlockTimestamp();
    marks.publish(1e18, 1e18, time, time + 60, 1);
    vm.deal(address(this), 5 ether); // Test ETH; no issuer/token storage edits.
    IWETH(ASSET).deposit{value: 2 ether}();
    IERC20(ASSET).approve(address(vault), 2 ether);
    vault.checkpointValuation();
    vault.deposit(2 ether, address(this));

    (bool ok,) = WSTETH.call{value: 1 ether}("");
    assertTrue(ok);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = IERC20(WSTETH).balanceOf(address(this));
    IERC20(WSTETH).approve(QUEUE, amounts[0]);
    uint256 id = Queue(QUEUE).requestWithdrawalsWstETH(amounts, address(this))[0];
    IERC721(QUEUE).approve(address(marks), id);
    address receipt = factory.wrap(address(marks), ClaimImport(CollateralKind.ERC721, QUEUE, id, 1, ""), address(this));
    uint256 route = book.registerClaimMarket(address(factory), receipt);
    vault.refreshStrategy(route);
    book.configurePricing(route, PricingPolicy(0.95e18, 1e18, 0.005e18, 0.005e18, 0, 0));
    book.publishPricing(route, PricingParameters(0.975e18, time, time + 60, 1, book.configVersion()));
    uint256 nominal = HarborClaimReceipt(payable(receipt)).entitlement();
    Trade memory t = Trade(
      address(this),
      address(this),
      receipt,
      ASSET,
      route,
      Side.BUY_BASE,
      AmountMode.EXACT_IN,
      1,
      0,
      time + 60,
      1,
      book.configVersion(),
      book.strategyVersion(route)
    );
    FillAmounts memory a = executor.quote(address(book), t);
    (uint256 quotedIn, uint256 quotedOut,) = executor.quoteSwap(address(book), t);
    assertEq(quotedIn, a.traderIn);
    assertEq(quotedOut, a.traderOut);
    uint256 bid = nominal * 97 / 100; // Independent expected price, below utilization threshold.
    assertLe(a.routerOut, bid);
    assertLe(bid - a.routerOut, 1); // Fee normalization can remove one wei of gross debit.
    IERC20(receipt).approve(address(executor), 1);
    uint256 beforeCash = IERC20(ASSET).balanceOf(address(this));
    uint256 issuerCash = QUEUE.balance;
    _assertFill(book, vault, executor, t);
    assertEq(IERC20(ASSET).balanceOf(address(this)), beforeCash + a.traderOut);
    assertEq(IERC20(ASSET).balanceOf(address(vault)), 2 ether - a.routerOut);
    assertEq(IERC20(receipt).balanceOf(address(vault)), 1);
    assertEq(IERC721(QUEUE).ownerOf(id), address(marks));
    assertEq(book.faceExposure(), nominal);
    assertEq(IERC20(ASSET).balanceOf(address(executor)), 0);
    assertEq(QUEUE.balance, issuerCash); // Purchase doesn't finalize or raid issuer cash.
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 2 ether - a.routerOut + nominal);

    // Buy the whole pending right back through the same standing publication.
    IERC20(ASSET).approve(address(executor), type(uint256).max);
    t.tokenIn = ASSET;
    t.tokenOut = receipt;
    t.side = Side.SELL_BASE;
    // Buyback requires separate cash for spread/fees; never rely on a test
    // address accidentally holding pre-existing tokens in the selected fork.
    IWETH(ASSET).deposit{value: 0.1 ether}();
    t.mode = AmountMode.EXACT_OUT;
    t.limitAmount = 1 ether;
    a = executor.quote(address(book), t);
    (quotedIn, quotedOut,) = executor.quoteSwap(address(book), t);
    assertEq(quotedIn, a.traderIn);
    assertEq(quotedOut, a.traderOut);
    beforeCash = IERC20(ASSET).balanceOf(address(vault));
    _assertFill(book, vault, executor, t);
    assertEq(IERC20(ASSET).balanceOf(address(vault)), beforeCash + a.routerIn);
    assertEq(IERC20(receipt).balanceOf(address(this)), 1);
    assertEq(book.faceExposure(), 0);
    // The other two modes reuse this same indivisible pending right.
    t.tokenIn = receipt;
    t.tokenOut = ASSET;
    t.side = Side.BUY_BASE;
    t.mode = AmountMode.EXACT_IN;
    t.amountSpecified = 1;
    t.limitAmount = 0;
    (quotedIn, quotedOut,) = executor.quoteSwap(address(book), t);
    t.mode = AmountMode.EXACT_OUT;
    t.amountSpecified = quotedOut;
    t.limitAmount = 1;
    IERC20(receipt).approve(address(executor), 1);
    _assertFill(book, vault, executor, t);
    t.tokenIn = ASSET;
    t.tokenOut = receipt;
    t.side = Side.SELL_BASE;
    t.mode = AmountMode.EXACT_OUT;
    t.amountSpecified = 1;
    t.limitAmount = 1 ether;
    (quotedIn, quotedOut,) = executor.quoteSwap(address(book), t);
    t.mode = AmountMode.EXACT_IN;
    t.amountSpecified = quotedIn;
    t.limitAmount = 1;
    _assertFill(book, vault, executor, t);
    assertEq(book.faceExposure(), 0);
    assertEq(book.activeReceiptCount(), 0);
    assertEq(IERC20(receipt).balanceOf(address(this)), 1);
    assertEq(IERC721(QUEUE).ownerOf(id), address(marks));
    assertEq(QUEUE.balance, issuerCash);
    vm.expectRevert();
    HarborClaimReceipt(payable(receipt)).recover(abi.encode(uint256(1)));
    vm.expectRevert(HarborClaimReceipt.InvalidState.selector);
    HarborClaimReceipt(payable(receipt)).redeem(address(this));
    assertEq(IERC20(receipt).totalSupply(), 1);
    assertEq(marks.totalClaimCash(), 0);
    vault.checkpointValuation();
    vault.requestRedeem(vault.balanceOf(address(this)), address(this), address(this));
    vault.fulfillWithdrawals(1);
    uint256 credit = vault.maxWithdraw(address(this));
    assertGt(credit, 2 ether);
    beforeCash = IERC20(ASSET).balanceOf(address(this));
    vault.withdraw(credit, address(this), address(this));
    assertEq(IERC20(ASSET).balanceOf(address(this)), beforeCash + credit);
    emit log_named_uint("fork_request_id", id);
    emit log_named_uint("actual_lp_cash_payout_wei", credit);
  }

  function _deployHarbor()
    private
    returns (HarborBook book, HarborVault vault, HarborExecutor executor, LidoAdapter marks)
  {
    Aqua aqua = Aqua(AQUA);
    HarborSwapVMRouter router = HarborSwapVMRouter(payable(ROUTER_ADDRESS));
    HarborClaimFactory factory = new HarborClaimFactory(ASSET, address(this), 1 days);
    executor = new HarborExecutor(address(router), address(this));
    uint64 nonce = vm.getNonce(address(this));
    address expectedAdapter = vm.computeCreateAddress(address(this), nonce + 2);
    HarborBook.Config memory c;
    c.vault = vm.computeCreateAddress(address(this), nonce + 1);
    c.executor = address(executor);
    c.asset = ASSET;
    c.aqua = address(aqua);
    c.router = address(router);
    c.updater = c.governor = c.guardian = c.keeper = address(this);
    c.feeRecipient = address(0xfee);
    c.feeBps = 10;
    c.maxParameterAge = c.maxMarkAge = 60;
    c.maxBasisExposure = 1000 ether;
    c.governanceDelay = 1 days;
    c.curve = PricingCurve(1000 ether, 0.6e18, 0.0025e18);
    RouteConfig[] memory routes = new RouteConfig[](1);
    routes[0] =
      RouteConfig(WSTETH, expectedAdapter, 0.99e18, 1.01e18, 0, 0, 1000 ether, 1000 ether, 10 ether, 100 ether);
    book = new HarborBook(c, routes);
    vault = new HarborVault(ASSET, address(book), 60, 1e12, 1e6);
    executor.registerPool(address(book));
    LidoAdapter adapter = new LidoAdapter(
      address(book),
      address(vault),
      WSTETH,
      ASSET,
      QUEUE,
      LidoViews.Config(address(factory), address(this), address(this), 60, 1 days)
    );
    marks = adapter;
    assertEq(address(adapter), expectedAdapter);
    assertEq(address(vault), c.vault);
    assertEq(address(executor), c.executor);
  }

  function test_ForkFourInventoryModesAndLpWithdrawal() public {
    (HarborBook book, HarborVault vault, HarborExecutor executor, LidoAdapter marks) = _deployHarbor();
    uint256 time = vm.getBlockTimestamp();
    marks.publish(1e18, 1e18, time, time + 60, 1);
    vm.deal(address(this), 10 ether);
    IWETH(ASSET).deposit{value: 5 ether}();
    IERC20(ASSET).approve(address(vault), 3 ether);
    vault.checkpointValuation();
    vault.deposit(3 ether, address(this));
    vault.refreshStrategy(0);
    book.configurePricing(0, PricingPolicy(0.95e18, 1e18, 0.01e18, 0.01e18, 0, 0));
    book.publishPricing(0, PricingParameters(1e18, time, time + 60, 1, book.configVersion()));
    (bool ok,) = WSTETH.call{value: 1 ether}("");
    assertTrue(ok);
    IERC20(WSTETH).approve(address(executor), type(uint256).max);
    IERC20(ASSET).approve(address(executor), type(uint256).max);
    uint256 issuerBefore = QUEUE.balance;
    for (uint256 i; i < 4; ++i) {
      bool buy = i < 2;
      // Two purchases, a partial cash-specified sale, then all remaining inventory.
      uint256 quantity = i == 3 ? book.getPosition(0).shares : i == 2 ? 0.05 ether : 0.1 ether;
      Trade memory t = Trade(
        address(this),
        address(this),
        buy ? WSTETH : ASSET,
        buy ? ASSET : WSTETH,
        0,
        buy ? Side.BUY_BASE : Side.SELL_BASE,
        buy ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT,
        quantity,
        buy ? 0 : type(uint256).max,
        time + 60,
        1,
        book.configVersion(),
        book.strategyVersion(0)
      );
      if (i == 1 || i == 2) {
        // Construct representable cash amounts from a base-specified preview.
        // This is input selection, not the independent expected-price assertion.
        (uint256 input, uint256 output,) = executor.quoteSwap(address(book), t);
        t.mode = buy ? AmountMode.EXACT_OUT : AmountMode.EXACT_IN;
        t.amountSpecified = buy ? output : input;
        t.limitAmount = buy ? type(uint256).max : 0;
      }
      _assertFill(book, vault, executor, t);
    }
    assertEq(book.faceExposure(), 0);
    assertEq(book.getPosition(0).shares, 0);
    assertEq(QUEUE.balance, issuerBefore);
    vault.checkpointValuation();
    vault.requestRedeem(vault.balanceOf(address(this)), address(this), address(this));
    vault.fulfillWithdrawals(1);
    uint256 credit = vault.maxWithdraw(address(this));
    assertGt(credit, 3 ether);
    uint256 beforeCash = IERC20(ASSET).balanceOf(address(this));
    vault.withdraw(credit, address(this), address(this));
    assertEq(IERC20(ASSET).balanceOf(address(this)), beforeCash + credit);
    assertEq(vault.maxWithdraw(address(this)), 0);
    assertEq(vault.balanceOf(address(this)), 0);
  }

  /// @dev Verify actual VM execution, independently expressed price/fee rounding,
  /// customer limits and conservation across trader, pool and protocol recipient.
  function _assertFill(HarborBook book, HarborVault vault, HarborExecutor executor, Trade memory t) private {
    FillAmounts memory a = executor.quote(address(book), t);
    (uint256 quotedIn, uint256 quotedOut, bytes32 hash) = executor.quoteSwap(address(book), t);
    assertEq(quotedIn, a.traderIn);
    assertEq(quotedOut, a.traderOut);
    assertEq(hash, keccak256(abi.encode(book.currentOrder(t.route))));
    bool buy = t.side == Side.BUY_BASE;
    uint256 quantity = buy ? a.traderIn : a.traderOut;
    uint256 face = t.route == 0
      ? IWstETHConversion(WSTETH).getStETHByWstETH(quantity)
      : HarborClaimReceipt(payable(book.route(t.route).base)).entitlement();
    uint256 gross = buy ? a.routerOut : a.traderIn;
    assertEq(a.fee, gross * 10 / 10_000);
    assertEq(buy ? a.traderOut + a.fee : a.routerIn + a.fee, gross);
    uint256 factor = t.route == 0 ? (buy ? 99 : 101) : (buy ? 97 : 98);
    uint256 expected = buy ? face * factor / 100 : (face * factor + 99) / 100;
    // Floor conversion and VM fee inversion can shift the cash pair by a few wei.
    assertApproxEqAbs(buy ? a.routerOut : a.routerIn, expected, 3);
    uint256 beforeIn = IERC20(t.tokenIn).balanceOf(address(this));
    uint256 beforeOut = IERC20(t.tokenOut).balanceOf(address(this));
    uint256 vaultIn = IERC20(t.tokenIn).balanceOf(address(vault));
    uint256 vaultOut = IERC20(t.tokenOut).balanceOf(address(vault));
    uint256 feeBefore = IERC20(ASSET).balanceOf(address(0xfee));
    t.limitAmount = t.mode == AmountMode.EXACT_IN ? a.traderOut : a.traderIn;
    (uint256 input, uint256 output) = executor.execute(address(book), t);
    assertEq(input, a.traderIn);
    assertEq(output, a.traderOut);
    assertEq(IERC20(t.tokenIn).balanceOf(address(this)), beforeIn - input);
    assertEq(IERC20(t.tokenOut).balanceOf(address(this)), beforeOut + output);
    assertEq(IERC20(t.tokenIn).balanceOf(address(vault)), vaultIn + a.routerIn);
    assertEq(IERC20(t.tokenOut).balanceOf(address(vault)), vaultOut - a.routerOut);
    assertEq(IERC20(ASSET).balanceOf(address(0xfee)), feeBefore + a.fee);
    assertEq(IERC20(t.tokenIn).balanceOf(address(executor)), 0);
    assertEq(IERC20(t.tokenOut).balanceOf(address(executor)), 0);
    assertEq(IERC20(t.tokenIn).allowance(address(executor), ROUTER_ADDRESS), 0);
    assertTrue(book.isIdle());
  }
}
