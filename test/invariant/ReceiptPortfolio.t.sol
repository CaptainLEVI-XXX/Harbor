// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedemptionMarketFixture} from "test/claims/RedemptionMarket.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {Side, AmountMode, Trade, FillTerms} from "src/types/HarborTypes.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

/// @notice Independent cash/cost ledger across repeated receipt purchases, resales and haircuts.
/// @dev Synthetic issuer finalization. Action counters ensure the seeded campaign executes trades.
contract ReceiptPortfolioInvariantTest is RedemptionMarketFixture {
  uint256 public currentRoute;
  uint256 public requestId;
  address public currentReceipt;
  uint256 public ghostCash;
  uint256 public ghostBasis;
  uint256 public ghostPurchases;
  uint256 public ghostLosses;
  uint256 public recoveryAmount;
  uint256 public positionVersion;
  uint256 public successfulTrades;
  bool public held;
  bool public finalized;
  bool public closed;

  function setUp() public override {
    super.setUp();
    ghostCash = weth.balanceOf(address(vault));
    (currentRoute, requestId, currentReceipt) = _externalMarket(1 ether);
    actionTrade(true, 0);
    actionTrade(false, 1);
    actionTrade(true, 1);
    actionFinalize(1.1 ether);
    actionRecover();
    actionNew();
    bytes4[] memory selectors = new bytes4[](4);
    selectors[0] = this.actionTrade.selector;
    selectors[1] = this.actionFinalize.selector;
    selectors[2] = this.actionRecover.selector;
    selectors[3] = this.actionNew.selector;
    targetSelector(FuzzSelector(address(this), selectors));
    targetContract(address(this));
  }

  function actionTrade(bool buy, uint8 mode) public {
    if (finalized || closed || buy == held || (buy && (ghostLosses >= 10 ether || ghostCash < 1.164 ether))) return;
    if (buy) {
      vm.prank(trader);
      IERC20(currentReceipt).approve(address(executor), 1);
    }
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) =
      _claimQuote(currentRoute, buy ? Side.BUY_BASE : Side.SELL_BASE, AmountMode(mode % 2));
    vm.prank(trader);
    executor.execute(t, f, sig, order);
    if (buy) {
      ghostCash -= f.routerOut;
      ghostBasis = f.routerOut;
      ghostPurchases += f.routerOut;
    } else {
      ghostCash += f.routerIn;
      if (ghostBasis > f.routerIn) ghostLosses += ghostBasis - f.routerIn;
      ghostBasis = 0;
    }
    held = buy;
    ++positionVersion;
    ++successfulTrades;
    vault.checkpointValuation();
  }

  function actionFinalize(uint96 amount) public {
    if (closed || finalized) return;
    recoveryAmount = bound(uint256(amount), 0, 1.2 ether);
    queue.setFinalized(requestId, recoveryAmount);
    finalized = true;
  }

  function actionRecover() public {
    if (!finalized || closed) return;
    if (held) {
      book.recoverClaim(currentRoute, 1);
      ++positionVersion;
      ghostCash += recoveryAmount;
      if (ghostBasis > recoveryAmount) ghostLosses += ghostBasis - recoveryAmount;
    } else {
      IHarborClaim(currentReceipt).recover(1);
      vm.prank(trader);
      IHarborClaim(currentReceipt).redeem(trader);
    }
    held = false;
    closed = true;
    ghostBasis = 0;
    vault.checkpointValuation();
  }

  function actionNew() public {
    if (!closed) return;
    bases[0].mint(trader, 1 ether);
    (currentRoute, requestId, currentReceipt) = _externalMarket(1 ether);
    finalized = false;
    closed = false;
    positionVersion = 0;
  }

  function invariant_CashCostAndIssuerBudgetsMatchIndependentLedger() public view {
    assertEq(weth.balanceOf(address(vault)), ghostCash);
    assertEq(book.claimTotals(0).basis, ghostBasis);
    assertEq(book.claimTotals(0).purchases, ghostPurchases);
    assertEq(book.claimTotals(0).losses, ghostLosses);
    assertEq(book.getPosition(currentRoute).basis, ghostBasis);
    assertEq(book.getPosition(currentRoute).shares, held ? 1 : 0);
    assertEq(book.activeReceiptCount(), held ? 1 : 0);
    assertEq(book.getPosition(currentRoute).version, positionVersion);
    assertEq(book.getPosition(currentRoute).purchases, 0);
    assertEq(book.getPosition(currentRoute).realizedLosses, 0);
    assertEq(IERC20(currentReceipt).balanceOf(address(vault)), held ? 1 : 0);
    assertEq(IERC20(currentReceipt).totalSupply(), closed ? 0 : 1);
    assertGe(successfulTrades, 3);
  }
}
