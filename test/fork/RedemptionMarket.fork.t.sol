// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {LidoViews} from "src/adapters/lido/LidoViews.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {HarborClaimReceipt} from "src/claims/HarborClaimReceipt.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {Trade, FillAmounts, RouteConfig, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingParameters, PricingCurve} from "src/types/PricingTypes.sol";
import {ILidoQueueHistory, HistoricalLidoHarness} from "test/fork/LidoAdapter.fork.t.sol";
import {ClaimImport, CollateralKind} from "src/types/ClaimTypes.sol";
import {WETH as WrappedEther} from "solady/tokens/WETH.sol";

/// @notice Mainnet-pinned issuer/token evidence with local official Aqua/router deployments.
/// @dev Real Harbor pricing, valuation and pooled execution with illustrative parameters; no token storage edits.
contract RedemptionMarketForkTest is Test {
  /// @dev Historical adapter-only test bindings; full-pool tests use their Book.
  function ROUTER() external view returns (address) {
    return address(this);
  }

  function WETH() external view returns (address) {
    return ASSET;
  }
  uint256 internal constant FORK_BLOCK = 25_930_239;
  address internal WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address internal ASSET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address internal QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

  function setUp() public {
    if (vm.envOr("HARBOR_TEST_HOODI", false)) {
      // Only the fresh-request test supports this mode. No public-chain writes:
      // actual Hoodi issuer state, locally deployed Solady wrapped cash/Aqua/VM.
      vm.createSelectFork(
        vm.envOr("HARBOR_HOODI_RPC_URL", string("https://ethereum-hoodi-rpc.publicnode.com")), 3_598_213
      );
      assertEq(block.chainid, 560048);
      WSTETH = 0x7E99eE3C66636DE415D2d7C880938F2f40f94De4;
      QUEUE = 0xfe56573178f1bcdf53F01A6E9977670dcBBD9186;
      ASSET = address(new WrappedEther());
      assertEq(ILidoQueueHistory(QUEUE).proxy__getImplementation(), 0xD0a60e52837e045F4567193Cf8921191C486eCD5);
      return;
    }
    vm.createSelectFork(vm.envOr("HARBOR_MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")), FORK_BLOCK);
    assertEq(block.chainid, 1);
    assertEq(ILidoQueueHistory(QUEUE).proxy__getImplementation(), 0xE42C659Dc09109566720EA8b2De186c2Be7D94D9);
  }

  function test_ForkNewLidoClaimTradesForRealWethThroughAquaSwapVM() public {
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
    executor.execute(address(book), t);
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
    IERC20(ASSET).approve(address(executor), 1 ether);
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
    executor.execute(address(book), t);
    assertEq(IERC20(ASSET).balanceOf(address(vault)), beforeCash + a.routerIn);
    assertEq(IERC20(receipt).balanceOf(address(this)), 1);
    assertEq(book.faceExposure(), 0);
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
    Aqua aqua = new Aqua();
    HarborSwapVMRouter router = new HarborSwapVMRouter(address(aqua), ASSET, address(this), "Harbor", "1");
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

  function isIdle() external pure returns (bool) {
    return true;
  }

  function test_ForkHistoricalRecoveryPaysActualIssuerCash() public {
    require(block.chainid == 1, "historical request is Ethereum mainnet only");
    uint256[] memory ids = new uint256[](1);
    ids[0] = 134_829;
    Queue.WithdrawalRequestStatus memory s = Queue(QUEUE).getWithdrawalStatus(ids)[0];
    assertTrue(s.isFinalized);
    assertFalse(s.isClaimed);
    HarborClaimFactory factory = new HarborClaimFactory(ASSET, address(this), 1 days);
    HistoricalLidoHarness adapter = new HistoricalLidoHarness(
      address(this),
      address(0xbeef),
      WSTETH,
      ASSET,
      QUEUE,
      LidoViews.Config(address(factory), address(this), address(this), 60, 1 days)
    );
    factory.schedule(address(adapter));
    vm.warp(vm.getBlockTimestamp() + 1 days);
    factory.activate(address(adapter));
    vm.prank(s.owner);
    IERC721(QUEUE).transferFrom(s.owner, address(adapter), ids[0]);
    adapter.seedHistoricalRight(ids[0]);
    HarborClaimReceipt receipt = HarborClaimReceipt(adapter.exportHistoricalRight(ids[0]));
    uint256[] memory hints =
      ILidoQueueHistory(QUEUE).findCheckpointHints(ids, 1, ILidoQueueHistory(QUEUE).getLastCheckpointIndex());
    uint256 expected = Queue(QUEUE).getClaimableEther(ids, hints)[0];
    uint256 beforeIssuer = QUEUE.balance;
    uint256 beforeOwner = IERC20(ASSET).balanceOf(address(this));
    assertEq(receipt.recover(abi.encode(hints[0])), expected);
    assertEq(receipt.redeem(address(this)), expected);
    assertEq(QUEUE.balance, beforeIssuer - expected);
    assertEq(IERC20(ASSET).balanceOf(address(this)), beforeOwner + expected);
    assertEq(receipt.totalSupply(), 0);
  }
}
