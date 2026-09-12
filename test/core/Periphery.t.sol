// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {Periphery} from "src/Periphery.sol";
import {Trade, Side, AmountMode} from "src/types/HarborTypes.sol";
import {TradingFixture} from "test/base/TradingFixture.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {VaultCore} from "src/vault/base/VaultCore.sol";

/// @dev Existing fixture minting plus WETH9's exact wrap and stipend-limited unwrap.
contract PeripheryWeth is TokenMock {
  constructor() TokenMock("Wrapped test ETH", "WETH") {}

  function deposit() external payable {
    _mint(msg.sender, msg.value);
  }

  function withdraw(uint256 amount) external {
    _burn(msg.sender, amount);
    payable(msg.sender).transfer(amount);
  }
}

contract RefundCaller {
  Periphery internal immutable periphery;
  address internal immutable book;
  bool public rejectedReentry;
  bool internal rejectRefund;

  constructor(Periphery p, address b) {
    periphery = p;
    book = b;
  }

  function run(bool reject) external payable {
    rejectRefund = reject;
    periphery.mint{value: msg.value}(book, 1e24);
  }

  function request(HarborVault vault) external {
    vault.setOperator(address(periphery), true);
    vault.requestRedeem(1e24, address(this), address(this));
  }

  function claim(bool reject) external {
    rejectRefund = reject;
    periphery.withdraw(book, 1 ether);
  }

  function sell(Trade calldata trade, bool reject) external {
    rejectRefund = reject;
    TokenMock(trade.tokenIn).approve(address(periphery), type(uint256).max);
    periphery.execute(book, trade);
  }

  receive() external payable {
    require(!rejectRefund, "refund rejected");
    try periphery.deposit{value: 1}(book, 0) {
      revert("reentry succeeded");
    } catch (bytes memory reason) {
      rejectedReentry = bytes4(reason) == bytes4(keccak256("Reentrancy()"));
    }
  }
}

/// @notice Native funding with real Harbor contracts and the official Aqua/VM machinery.
contract PeripheryTest is TradingFixture {
  Periphery internal periphery;

  function setUp() public override {
    super.setUp();
    periphery = new Periphery(address(weth), address(executor));
    vm.deal(trader, 10 ether);
    vm.deal(address(weth), 200 ether); // Back the fixture's synthetic pre-minted WETH for native payouts.
  }

  function _deployWeth() internal override returns (TokenMock) {
    return new PeripheryWeth();
  }

  function testFuzz_DepositMintAndDonationIsolation(uint96 raw) public {
    uint256 assets = bound(uint256(raw), 1e12, 2 ether);
    weth.mint(address(periphery), 7);
    vm.deal(address(periphery), 11); // Forced ETH is not the next caller's refund.
    uint256 beforeShares = vault.balanceOf(trader);
    vm.startPrank(trader);
    assertEq(periphery.deposit{value: assets}(address(book), assets * 1e6), assets * 1e6);
    assertEq(periphery.mint{value: 2 ether}(address(book), 1e24), 1 ether);
    vm.stopPrank();
    assertEq(vault.balanceOf(trader) - beforeShares, (assets + 1 ether) * 1e6);
    assertEq(trader.balance, 9 ether - assets);
    assertEq(weth.balanceOf(address(vault)), 21 ether + assets);
    assertEq(weth.balanceOf(address(periphery)), 7);
    assertEq(address(periphery).balance, 11);
    assertEq(weth.allowance(address(periphery), address(vault)), 0);
  }

  function test_ExactInputAndOutputUseVMAndRefundOnlyUnspentETH() public {
    _buy(0, 4 ether); // Managed inventory, not an unaccounted donation.
    for (uint256 i; i < 2; ++i) {
      Trade memory t = _trade(
        0,
        Side.SELL_BASE,
        i == 0 ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT,
        i == 0 ? 1.02 ether : 2 ether,
        i == 0 ? 0 : 1 ether
      );
      t.trader = address(periphery);
      (uint256 quotedIn, uint256 quotedOut,) = executor.quoteSwap(address(book), t);
      uint256 beforeBase = bases[0].balanceOf(trader);
      uint256 beforeEth = trader.balance;
      vm.prank(trader);
      (uint256 input, uint256 output) = periphery.execute{value: i == 0 ? 1.02 ether : 2 ether}(address(book), t);
      assertEq(input, quotedIn);
      assertEq(output, quotedOut);
      assertEq(beforeEth - trader.balance, input);
      assertEq(bases[0].balanceOf(trader) - beforeBase, output);
      if (i == 1) {
        assertEq(output, 1 ether);
        // For this amount, the VM's floor-fee inverse is the smallest gross
        // payment covering 1:1 entitlement plus a 1% ask margin.
        assertEq(input - input * 10 / 10000, 1.01 ether);
        assertLt((input - 1) - (input - 1) * 10 / 10000, 1.01 ether);
      }
      assertEq(weth.allowance(address(periphery), address(executor)), 0);
      assertEq(weth.balanceOf(address(periphery)), 0);
      assertEq(address(periphery).balance, 0);
    }
  }

  function test_DepositSlippageAndUnderfundedMintRollBackWrapping() public {
    vm.startPrank(trader);
    vm.expectRevert(Periphery.InsufficientOutput.selector);
    periphery.deposit{value: 1 ether}(address(book), 1e24 + 1);
    vm.expectRevert();
    periphery.mint{value: 1 ether}(address(book), 2e24);
    vm.stopPrank();
    assertEq(trader.balance, 10 ether);
    assertEq(vault.balanceOf(trader), 0);
    assertEq(weth.balanceOf(address(vault)), 20 ether);
    assertEq(weth.balanceOf(address(periphery)), 0);
    assertEq(weth.allowance(address(periphery), address(vault)), 0);
  }

  function test_TargetAndRecipientCannotBeSubstituted() public {
    vm.startPrank(trader);
    vm.expectRevert(Periphery.InvalidTarget.selector);
    periphery.deposit{value: 1 ether}(address(123), 0);
    Trade memory t = _trade(0, Side.SELL_BASE, AmountMode.EXACT_IN, 1 ether, 0);
    vm.expectRevert(Periphery.InvalidIntent.selector); // Original EOA is not the funding trader.
    periphery.execute{value: 1 ether}(address(book), t);
    t.trader = address(periphery);
    t.receiver = alice;
    vm.expectRevert(Periphery.InvalidIntent.selector);
    periphery.execute{value: 1 ether}(address(book), t);
    vm.stopPrank();
    assertEq(trader.balance, 10 ether);
  }

  function test_LateSwapFailureRollsBackWrappingAndPortfolio() public {
    _buy(0, 2 ether);
    Trade memory t = _trade(0, Side.SELL_BASE, AmountMode.EXACT_OUT, 2 ether, 1 ether);
    t.trader = address(periphery);
    uint256 cash = weth.balanceOf(address(vault));
    uint256 base = bases[0].balanceOf(trader);
    vm.mockCallRevert(
      address(bases[0]), abi.encodeWithSignature("transfer(address,uint256)", trader, 1 ether), "late payout"
    );
    vm.prank(trader);
    vm.expectRevert();
    periphery.execute{value: 2 ether}(address(book), t);
    assertEq(trader.balance, 10 ether);
    assertEq(bases[0].balanceOf(trader), base);
    assertEq(book.getPosition(0).shares, 2 ether);
    assertEq(weth.balanceOf(address(vault)), cash);
    assertEq(weth.balanceOf(address(periphery)), 0);
    assertEq(weth.allowance(address(periphery), address(executor)), 0);
  }

  function test_RefundReentrancyAndRejectingReceiver() public {
    RefundCaller caller = new RefundCaller(periphery, address(book));
    vm.deal(address(this), 4 ether);
    caller.run{value: 2 ether}(false);
    assertTrue(caller.rejectedReentry());
    assertEq(vault.balanceOf(address(caller)), 1e24);
    assertEq(address(caller).balance, 1 ether);
    vm.expectRevert();
    caller.run{value: 2 ether}(true);
    assertEq(vault.balanceOf(address(caller)), 1e24);
    assertEq(address(caller).balance, 1 ether);
    assertEq(weth.balanceOf(address(periphery)), 0);
    caller.request(vault);
    vault.fulfillWithdrawals(1);
    vm.expectRevert();
    caller.claim(true);
    assertEq(vault.maxWithdraw(address(caller)), 1 ether);
    caller.claim(false);
    assertTrue(caller.rejectedReentry());
    assertEq(vault.maxWithdraw(address(caller)), 0);
    assertEq(address(caller).balance, 2 ether);
  }

  function test_DepositRequestFundAndBothNativeClaimModes() public {
    vm.startPrank(trader);
    periphery.deposit{value: 2 ether}(address(book), 2e24);
    vault.requestRedeem(2e24, trader, trader);
    vm.expectRevert(VaultCore.Unauthorized.selector);
    periphery.withdraw(address(book), 1 ether);
    vault.setOperator(address(periphery), true);
    vm.expectRevert(); // Pending shares cannot be spent as cash.
    periphery.withdraw(address(book), 1 ether);
    vm.stopPrank();
    vault.fulfillWithdrawals(1);
    assertEq(vault.maxWithdraw(trader), 2 ether);
    weth.mint(address(periphery), 7);
    vm.deal(address(periphery), 11);
    // A different caller cannot select trader as the controller, even with approval.
    vm.prank(bob);
    vm.expectRevert(VaultCore.Unauthorized.selector);
    periphery.withdraw(address(book), 1 ether);
    vm.startPrank(trader);
    vault.setOperator(address(periphery), false);
    vm.expectRevert(VaultCore.Unauthorized.selector);
    periphery.withdraw(address(book), 1 ether);
    vault.setOperator(address(periphery), true);
    vm.stopPrank();
    valuation.setValid(false); // Funded exits do not need fresh portfolio pricing.
    vm.startPrank(trader);
    assertEq(periphery.withdraw(address(book), 0.5 ether), 5e23);
    vm.expectRevert(Periphery.InsufficientOutput.selector);
    periphery.redeem(address(book), 1.5e24, 1.5 ether + 1);
    assertEq(periphery.redeem(address(book), 1.5e24, 1.5 ether), 1.5 ether);
    vm.expectRevert();
    periphery.withdraw(address(book), 1);
    vm.stopPrank();
    assertEq(trader.balance, 10 ether);
    assertEq(vault.maxWithdraw(trader), 0);
    assertEq(vault.claimableRedeemRequest(0, trader), 0);
    assertEq(weth.balanceOf(address(periphery)), 7);
    assertEq(address(periphery).balance, 11);
  }

  function test_BothNativeSellModesLeaveUnusedTokensInWallet() public {
    bases[0].mint(address(periphery), 7);
    weth.mint(address(periphery), 11);
    vm.deal(address(periphery), 13);
    vm.prank(trader);
    bases[0].approve(address(periphery), type(uint256).max);
    for (uint256 i; i < 2; ++i) {
      Trade memory t =
        _trade(0, Side.BUY_BASE, i == 0 ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT, 1 ether, i == 0 ? 0 : 0.5 ether);
      t.trader = address(periphery);
      (uint256 input, uint256 output,) = executor.quoteSwap(address(book), t);
      uint256 beforeTokens = bases[0].balanceOf(trader);
      uint256 beforeEth = trader.balance;
      vm.prank(trader);
      (uint256 actualIn, uint256 actualOut) = periphery.execute(address(book), t);
      assertEq(actualIn, input);
      assertEq(actualOut, output);
      assertEq(bases[0].balanceOf(trader), beforeTokens - input);
      assertEq(trader.balance, beforeEth + output);
      assertEq(bases[0].balanceOf(address(periphery)), 7);
      assertEq(weth.balanceOf(address(periphery)), 11);
      assertEq(address(periphery).balance, 13);
      assertEq(bases[0].allowance(address(periphery), address(executor)), 0);
    }
  }

  function test_NativeSellPayoutFailureRollbackAndReentrancy() public {
    RefundCaller caller = new RefundCaller(periphery, address(book));
    bases[0].mint(address(caller), 1 ether);
    Trade memory t = _trade(0, Side.BUY_BASE, AmountMode.EXACT_IN, 1 ether, 0);
    t.trader = address(periphery);
    t.receiver = address(caller);
    vm.expectRevert();
    caller.sell(t, true);
    assertEq(bases[0].balanceOf(address(caller)), 1 ether);
    assertEq(book.getPosition(0).shares, 0);
    assertEq(weth.balanceOf(address(vault)), 20 ether);
    caller.sell(t, false);
    assertTrue(caller.rejectedReentry());
    assertEq(bases[0].balanceOf(address(caller)), 0);
    assertEq(address(caller).balance, 0.98901 ether); // 99% bid less floor(10 bps).
    assertEq(weth.balanceOf(address(periphery)), 0);
    t.receiver = feeRecipient;
    vm.prank(feeRecipient);
    vm.expectRevert(); // Original receiver policy survives internal redirection to Periphery.
    periphery.execute(address(book), t);
  }
}
