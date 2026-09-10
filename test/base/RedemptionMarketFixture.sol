// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/base/IssuerFixture.sol";
import {LidoClaimFactory} from "src/claims/LidoClaimFactory.sol";
import {Trade, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingPolicy} from "src/types/PricingTypes.sol";
import {Fees} from "src/libraries/Fees.sol";
import {Amounts} from "src/libraries/Amounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Whole receipts through actual Aqua/SwapVM transfers; issuer inputs are synthetic.
abstract contract RedemptionMarketFixture is IssuerFixture {
  LidoClaimFactory internal factory;

  function setUp() public virtual override {
    super.setUp();
    _buy(0, 4 ether);
    factory = new LidoClaimFactory(address(queue), address(weth), address(this));
    book.scheduleClaimFactory(address(factory), 0, 0.97e18, 0.98e18);
    vm.warp(vm.getBlockTimestamp() + 1 days);
    valuation.setObservedAt(vm.getBlockTimestamp());
    book.activateClaimFactory(address(factory));
    _publish(0, 1e18);
    _publish(1, 1e18);
    vault.checkpointValuation();
  }

  function _configureReceipt(uint256 route) internal {
    book.configurePricing(route, PricingPolicy(0.95e18, 1e18, 0.005e18, 0.005e18, 0, 0));
    _publish(route, 0.975e18);
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
    _configureReceipt(route);
  }

  function _claimQuote(uint256 route, Side side, AmountMode mode)
    internal
    view
    returns (Trade memory t, FillAmounts memory a)
  {
    bool buy = side == Side.BUY_BASE;
    (uint256 face,,,,,) = book.observation(route, 1);
    uint256 input = buy ? 1 : Fees.grossForNet(face * 98 / 100, 10);
    uint256 output = buy ? Fees.net(face * 97 / 100, 10) : 1;
    t = _trade(route, side, mode, input, output);
    a = Amounts.normalize(t, input, output, 10);
  }

  function _tradeClaim(uint256 route, Side side, AmountMode mode) internal {
    (Trade memory t, FillAmounts memory expected) = _claimQuote(route, side, mode);
    FillAmounts memory actual = executor.quote(t);
    assertEq(abi.encode(actual), abi.encode(expected));
    vm.prank(trader);
    executor.execute(t);
    vault.checkpointValuation();
  }
}
