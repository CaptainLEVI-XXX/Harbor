// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Periphery} from "src/Periphery.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {Trade, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingParameters} from "src/types/PricingTypes.sol";
import {ClaimImport, CollateralKind} from "src/types/ClaimTypes.sol";

/// @notice Existing Hoodi WETH and registered Vault; no broadcasts or mocked token behavior.
contract PeripheryHoodiTest is Test {
  function test_HoodiWrapDepositMintAndNativeRefund() public {
    vm.createSelectFork("hoodi", 3_608_981);
    address weth = 0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E;
    address book = 0x056349edd023191eab7e9E93c376B08de34494DB;
    HarborVault vault = HarborVault(0x4c5BfF5143aa26BBb84535df27704B32091ecD25);
    Periphery p = new Periphery(weth, 0xF7c2593Ba433C261eee79eEc4bcaEbA97636083d);
    address user = address(0xa11ce);
    vm.deal(user, 3 ether);
    uint256 cash = IERC20(weth).balanceOf(address(vault));
    vm.startPrank(user);
    assertEq(p.deposit{value: 1 ether}(book, 1e24), 1e24);
    assertEq(p.mint{value: 1 ether}(book, 5e23), 0.5 ether);
    vm.stopPrank();
    assertEq(user.balance, 1.5 ether);
    assertEq(vault.balanceOf(user), 1.5e24);
    assertEq(IERC20(weth).balanceOf(address(vault)), cash + 1.5 ether);
    assertEq(IERC20(weth).balanceOf(address(p)), 0);
    assertEq(IERC20(weth).allowance(address(p), address(vault)), 0);
    assertEq(address(p).balance, 0);
    vm.startPrank(user);
    vault.setOperator(address(p), true);
    vault.requestRedeem(1.5e24, user, user);
    vm.stopPrank();
    vault.fulfillWithdrawals(1);
    vm.startPrank(user);
    assertEq(p.withdraw(book, 1 ether), 1e24);
    assertEq(p.redeem(book, 5e23, 0.5 ether), 0.5 ether);
    vm.stopPrank();
    assertEq(user.balance, 3 ether);
    assertEq(vault.maxWithdraw(user), 0);
    assertEq(IERC20(weth).balanceOf(address(vault)), cash);
    assertEq(IERC20(weth).balanceOf(address(p)), 0);
    assertEq(address(p).balance, 0);
  }
}

/// @notice Real deployed Harbor, Aqua, SwapVM, WETH and Lido; only Periphery is new.
/// Test ETH and governor impersonation are fork-only. No token storage edits or mocks.
contract PeripheryTradingHoodiTest is Test {
  address constant WETH = 0xE0decAa66aED871ac9eb924443D1Bf333Fdb062E;
  address constant WSTETH = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;
  address constant QUEUE = 0xfe56573178f1bcdf53F01A6E9977670dcBBD9186;
  address constant USER = address(0xbabe);
  HarborBook book = HarborBook(0x056349edd023191eab7e9E93c376B08de34494DB);
  HarborVault vault = HarborVault(0x4c5BfF5143aa26BBb84535df27704B32091ecD25);
  HarborExecutor executor = HarborExecutor(0xF7c2593Ba433C261eee79eEc4bcaEbA97636083d);
  Periphery p;

  function setUp() public {
    vm.createSelectFork("hoodi", 3_608_981);
    p = new Periphery(WETH, address(executor));
    vm.deal(USER, 5 ether);
    vm.startPrank(USER);
    p.deposit{value: 2 ether}(address(book), 0);
    (bool ok,) = WSTETH.call{value: 0.2 ether}("");
    assertTrue(ok, "stake ETH through real Lido");
    vm.stopPrank();
    vm.prank(book.GOVERNOR());
    vault.refreshStrategy(0);
  }

  function test_ForkFourInventoryModesNativeSettlement() public {
    uint256 beforePosition = book.getPosition(0).shares;
    uint256 beforeToken = IERC20(WSTETH).balanceOf(USER);
    vm.prank(USER);
    IERC20(WSTETH).approve(address(p), type(uint256).max);
    _roundTrips(0, WSTETH, 0.01 ether);
    assertEq(book.getPosition(0).shares, beforePosition);
    assertEq(IERC20(WSTETH).balanceOf(USER), beforeToken);
  }

  function test_ForkFourWholeReceiptModesNativeSettlement() public {
    LidoAdapter adapter = LidoAdapter(payable(book.route(0).adapter));
    HarborClaimFactory factory = HarborClaimFactory(adapter.FACTORY());
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 0.02 ether;
    vm.startPrank(USER);
    IERC20(WSTETH).approve(QUEUE, amounts[0]);
    uint256 id = Queue(QUEUE).requestWithdrawalsWstETH(amounts, USER)[0];
    IERC721(QUEUE).approve(address(adapter), id);
    address receipt = factory.wrap(address(adapter), ClaimImport(CollateralKind.ERC721, QUEUE, id, 1, ""), USER);
    vm.stopPrank();
    vm.startPrank(book.GOVERNOR());
    uint256 route = book.registerClaimMarket(address(factory), receipt);
    book.configurePricing(route, PricingPolicy(0.95e18, 1e18, 0.005e18, 0.005e18, 0, 0));
    book.publishPricing(
      route, PricingParameters(0.975e18, block.timestamp, block.timestamp + 1 days, 1, book.configVersion())
    );
    vault.refreshStrategy(route);
    vm.stopPrank();
    Trade memory t = _trade(route, receipt, true, 1);
    vm.prank(USER);
    vm.expectRevert(); // Receipt approval is to Periphery, not Executor.
    p.execute(address(book), t);
    assertEq(IERC20(receipt).balanceOf(USER), 1);
    vm.prank(USER);
    IERC20(receipt).approve(address(p), type(uint256).max);
    _roundTrips(route, receipt, 1);
    assertEq(IERC20(receipt).balanceOf(USER), 1);
    assertEq(IERC20(receipt).totalSupply(), 1);
    assertEq(IERC721(QUEUE).ownerOf(id), address(adapter));
    assertEq(IERC20(receipt).balanceOf(address(vault)), 0);
  }

  /// @dev Sell exact-in, buy exact-out, sell exact-out, buy exact-in. Construct
  /// representable exact cash sizes using the VM; assert actual balance conservation.
  function _roundTrips(uint256 route, address token, uint256 quantity) private {
    for (uint256 i; i < 4; ++i) {
      bool sell = i % 2 == 0;
      Trade memory t = _trade(route, token, sell, quantity);
      (uint256 input, uint256 output,) = executor.quoteSwap(address(book), t);
      if (i == 2) {
        t.mode = AmountMode.EXACT_OUT;
        t.amountSpecified = output;
        t.limitAmount = quantity + 1; // A receipt holder has one token, not maxIn=2.
      } else if (i == 3) {
        t.mode = AmountMode.EXACT_IN;
        t.amountSpecified = input;
        t.limitAmount = quantity;
      }
      uint256[3] memory beforeBalances =
        [USER.balance, IERC20(token).balanceOf(USER), IERC20(WETH).balanceOf(address(vault))];
      uint256 value = sell ? 0 : t.mode == AmountMode.EXACT_IN ? t.amountSpecified : t.limitAmount;
      vm.prank(USER);
      (uint256 actualIn, uint256 actualOut) = p.execute{value: value}(address(book), t);
      assertEq(actualIn, input);
      assertEq(actualOut, output);
      assertEq(USER.balance, sell ? beforeBalances[0] + output : beforeBalances[0] - input);
      assertEq(IERC20(token).balanceOf(USER), sell ? beforeBalances[1] - input : beforeBalances[1] + output);
      // Existing demo pool has zero protocol fees; WETH becomes native 1:1.
      assertEq(IERC20(WETH).balanceOf(address(vault)), sell ? beforeBalances[2] - output : beforeBalances[2] + input);
      assertEq(IERC20(token).balanceOf(address(p)), 0);
      assertEq(IERC20(WETH).balanceOf(address(p)), 0);
      assertEq(address(p).balance, 0);
      assertEq(IERC20(token).allowance(address(p), address(executor)), 0);
      assertEq(IERC20(WETH).allowance(address(p), address(executor)), 0);
      assertTrue(book.isIdle());
    }
  }

  function _trade(uint256 route, address token, bool sell, uint256 quantity) private view returns (Trade memory) {
    return Trade(
      address(p),
      USER,
      sell ? token : WETH,
      sell ? WETH : token,
      route,
      sell ? Side.BUY_BASE : Side.SELL_BASE,
      sell ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT,
      quantity,
      sell ? 0 : 0.2 ether,
      block.timestamp + 300,
      book.pricingParameters(route).version,
      book.configVersion(),
      book.strategyVersion(route)
    );
  }
}
