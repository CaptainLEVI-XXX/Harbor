// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/helpers/IssuerFixture.sol";
import {LidoClaimFactory} from "src/claims/LidoClaimFactory.sol";
import {Trade, FillTerms, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {Fees} from "src/libraries/Fees.sol";
import {Amounts} from "src/libraries/Amounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

/// @notice Whole-position trades through official Aqua and the Harbor SwapVM router.
/// @dev Issuer finalization/marks are synthetic; balances and settlements are actual EVM transfers.
abstract contract RedemptionMarketFixture is IssuerFixture {
  LidoClaimFactory internal factory;
  uint256 internal claimNonce = 10000;

  function setUp() public virtual override {
    super.setUp();
    _buy(0, 4 ether);
    factory = new LidoClaimFactory(address(queue), address(weth), address(this));
    book.scheduleClaimFactory(address(factory), 0, 0.97e18, 0.98e18);
    vm.warp(block.timestamp + 1 days);
    valuation.setObservedAt(block.timestamp);
    book.activateClaimFactory(address(factory));
    vault.checkpointValuation();
  }

  function _externalMarket(uint256 amount) internal returns (uint256 route, uint256 id, address receipt) {
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    vm.startPrank(trader);
    bases[0].approve(address(queue), amount);
    id = queue.requestWithdrawalsWstETH(amounts, trader)[0];
    queue.approve(address(factory), id);
    receipt = factory.wrap(id);
    IERC20(receipt).approve(address(executor), 1);
    vm.stopPrank();
    route = book.registerClaimMarket(address(factory), receipt);
    vault.refreshStrategy(route);
  }

  function _claimQuote(uint256 route, Side side, AmountMode mode)
    internal
    returns (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order)
  {
    bool buy = side == Side.BUY_BASE;
    (uint256 value,, uint256 time,, bytes32 observation,) = book.observation(route, 1);
    uint256 input = buy ? 1 : Fees.grossForNet(value * 98 / 100, 10);
    uint256 output = buy ? Fees.net(value * 97 / 100, 10) : 1;
    address receipt = book.route(route).base;
    t = Trade(
      trader,
      trader,
      buy ? receipt : address(weth),
      buy ? address(weth) : receipt,
      route,
      side,
      mode,
      mode == AmountMode.EXACT_IN ? input : output,
      mode == AmountMode.EXACT_IN ? output : input,
      block.timestamp + 60,
      ++claimNonce
    );
    FillAmounts memory a = Amounts.normalize(t, input, output, 10);
    order = book.currentOrder(route);
    f.vault = address(vault);
    f.adapter = address(factory);
    f.feeRecipient = feeRecipient;
    f.strategyVersion = book.strategyVersion(route);
    f.adapterVersion = factory.version();
    f.epoch = book.quoteEpoch();
    f.nonce = claimNonce;
    f.portfolioVersion = book.portfolioVersion();
    f.positionVersion = book.getPosition(route).version;
    (, f.valuationVersion,) = vault.valuationIdentity();
    f.policyVersion = 1;
    f.traderIn = input;
    f.traderOut = output;
    f.routerIn = a.routerIn;
    f.routerOut = a.routerOut;
    f.fee = a.fee;
    f.feeBps = 10;
    f.observedAt = time;
    f.validUntil = block.timestamp + 60;
    f.orderHash = router.hash(order);
    f.observationHash = observation;
    sig = _sign(t, f);
  }

  function _tradeClaim(uint256 route, Side side, AmountMode mode) internal {
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) = _claimQuote(route, side, mode);
    (uint256 quotedIn, uint256 quotedOut) = executor.quoteFill(t, f, sig, order);
    assertEq(quotedIn, f.routerIn);
    assertEq(quotedOut, f.routerOut);
    assertFalse(book.usedQuoteNonce(f.epoch, f.nonce));
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    assertTrue(book.usedQuoteNonce(f.epoch, f.nonce));
    vault.checkpointValuation();
  }
}
