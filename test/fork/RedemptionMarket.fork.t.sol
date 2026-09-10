// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {LidoClaimFactory} from "src/claims/LidoClaimFactory.sol";
import {LidoClaimReceipt} from "src/claims/LidoClaimReceipt.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {LidoValuation} from "src/valuation/LidoValuation.sol";
import {Trade, FillAmounts, RouteConfig, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingParameters, PricingCurve} from "src/types/PricingTypes.sol";
import {ILidoQueueHistory} from "test/fork/LidoAdapter.fork.t.sol";

/// @notice TEST ONLY: seed a separately mature historical right to isolate actual recovery.
/// @dev This entrypoint is absent from canonical factory receipts. It proves neither
/// maturation of the new request nor admission of finalized receipts to trading.
contract HistoricalReceiptHarness is LidoClaimReceipt {
  constructor(address issuer, address weth) LidoClaimReceipt(issuer, weth) {}

  function seed(uint256 entitlement_) external {
    require(msg.sender == FACTORY && REQUEST_ID != 0 && _state == Status.UNINITIALIZED);
    require(Queue(ISSUER).ownerOf(REQUEST_ID) == address(this));
    entitlement = entitlement_;
    _state = Status.PENDING;
    _mint(msg.sender, 1);
  }
}

/// @notice Mainnet-pinned issuer/token evidence with local official Aqua/router deployments.
/// @dev Real Harbor pricing, valuation and pooled execution with illustrative parameters; no token storage edits.
contract RedemptionMarketForkTest is Test {
  uint256 internal constant FORK_BLOCK = 25_930_239;
  address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
  address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address internal constant QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

  function setUp() public {
    vm.createSelectFork(vm.envOr("HARBOR_MAINNET_RPC_URL", string("https://ethereum-rpc.publicnode.com")), FORK_BLOCK);
    assertEq(block.chainid, 1);
    assertEq(ILidoQueueHistory(QUEUE).proxy__getImplementation(), 0xE42C659Dc09109566720EA8b2De186c2Be7D94D9);
  }

  function test_ForkNewLidoClaimTradesForRealWethThroughAquaSwapVM() public {
    (HarborBook book, HarborVault vault, HarborExecutor executor, LidoValuation marks) = _deployHarbor();
    LidoClaimFactory factory = new LidoClaimFactory(QUEUE, WETH, address(this));
    book.scheduleClaimFactory(address(factory), 0, 0.97e18, 0.98e18);
    vm.warp(vm.getBlockTimestamp() + 1 days); // Admission delay, not issuer finalization.
    book.activateClaimFactory(address(factory));
    uint256 time = vm.getBlockTimestamp();
    marks.publish(1e18, 1e18, time, time + 60, 1);
    vm.deal(address(this), 5 ether); // Test ETH; no issuer/token storage edits.
    IWETH(WETH).deposit{value: 2 ether}();
    IERC20(WETH).approve(address(vault), 2 ether);
    vault.checkpointValuation();
    vault.deposit(2 ether, address(this));

    (bool ok,) = WSTETH.call{value: 1 ether}("");
    assertTrue(ok);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = IERC20(WSTETH).balanceOf(address(this));
    IERC20(WSTETH).approve(QUEUE, amounts[0]);
    uint256 id = Queue(QUEUE).requestWithdrawalsWstETH(amounts, address(this))[0];
    IERC721(QUEUE).approve(address(factory), id);
    address receipt = factory.wrap(id);
    uint256 route = book.registerClaimMarket(address(factory), receipt);
    vault.refreshStrategy(route);
    book.configurePricing(route, PricingPolicy(0.95e18, 1e18, 0.005e18, 0.005e18, 0, 0));
    book.publishPricing(route, PricingParameters(0.975e18, time, time + 60, 1, book.configVersion()));
    uint256 nominal = LidoClaimReceipt(payable(receipt)).entitlement();
    Trade memory t = Trade(
      address(this),
      address(this),
      receipt,
      WETH,
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
    FillAmounts memory a = executor.quote(t);
    uint256 bid = nominal * 97 / 100; // Independent expected price, below utilization threshold.
    assertLe(a.routerOut, bid);
    assertLe(bid - a.routerOut, 1); // Fee normalization can remove one wei of gross debit.
    IERC20(receipt).approve(address(executor), 1);
    uint256 beforeCash = IERC20(WETH).balanceOf(address(this));
    uint256 issuerCash = QUEUE.balance;
    executor.execute(t);
    assertEq(IERC20(WETH).balanceOf(address(this)), beforeCash + a.traderOut);
    assertEq(IERC20(WETH).balanceOf(address(vault)), 2 ether - a.routerOut);
    assertEq(IERC20(receipt).balanceOf(address(vault)), 1);
    assertEq(IERC721(QUEUE).ownerOf(id), receipt);
    assertEq(book.faceExposure(), nominal);
    assertEq(IERC20(WETH).balanceOf(address(executor)), 0);
    assertEq(QUEUE.balance, issuerCash); // Purchase doesn't finalize or raid issuer cash.
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 2 ether - a.routerOut + nominal);

    // Buy the whole pending right back through the same standing publication.
    IERC20(WETH).approve(address(executor), 1 ether);
    t.tokenIn = WETH;
    t.tokenOut = receipt;
    t.side = Side.SELL_BASE;
    t.mode = AmountMode.EXACT_OUT;
    t.limitAmount = 1 ether;
    a = executor.quote(t);
    beforeCash = IERC20(WETH).balanceOf(address(vault));
    executor.execute(t);
    assertEq(IERC20(WETH).balanceOf(address(vault)), beforeCash + a.routerIn);
    assertEq(IERC20(receipt).balanceOf(address(this)), 1);
    assertEq(book.faceExposure(), 0);
    vault.checkpointValuation();
    vault.requestRedeem(vault.balanceOf(address(this)), address(this), address(this));
    vault.fulfillWithdrawals(1);
    uint256 credit = vault.maxWithdraw(address(this));
    assertGt(credit, 2 ether);
    beforeCash = IERC20(WETH).balanceOf(address(this));
    vault.withdraw(credit, address(this), address(this));
    assertEq(IERC20(WETH).balanceOf(address(this)), beforeCash + credit);
    emit log_named_uint("fork_request_id", id);
    emit log_named_uint("actual_lp_cash_payout_wei", credit);
  }

  function _deployHarbor()
    private
    returns (HarborBook book, HarborVault vault, HarborExecutor executor, LidoValuation marks)
  {
    Aqua aqua = new Aqua();
    HarborSwapVMRouter router = new HarborSwapVMRouter(address(aqua), WETH, address(this), "Harbor", "1");
    uint64 nonce = vm.getNonce(address(this));
    address expectedAdapter = vm.computeCreateAddress(address(this), nonce + 4);
    marks =
      new LidoValuation(LidoValuation.Config(WSTETH, QUEUE, expectedAdapter, address(this), address(this), 60, 1 days));
    HarborBook.Config memory c;
    c.vault = vm.computeCreateAddress(address(this), nonce + 2);
    c.executor = vm.computeCreateAddress(address(this), nonce + 3);
    c.weth = WETH;
    c.aqua = address(aqua);
    c.router = address(router);
    c.updater = c.governor = c.guardian = c.keeper = address(this);
    c.valuation = address(marks);
    c.feeRecipient = address(0xfee);
    c.feeBps = 10;
    c.maxParameterAge = c.maxMarkAge = 60;
    c.depositCap = 1000 ether;
    c.governanceDelay = 1 days;
    c.curve = PricingCurve(1000 ether, 0.6e18, 0.0025e18);
    RouteConfig[] memory routes = new RouteConfig[](1);
    routes[0] =
      RouteConfig(WSTETH, expectedAdapter, 0.99e18, 1.01e18, 0, 0, 1000 ether, 1000 ether, 10 ether, 100 ether);
    book = new HarborBook(c, routes);
    vault = new HarborVault(WETH, address(book), 60, 1000 ether, 1e12, 1e6);
    executor = new HarborExecutor(address(book), address(vault), address(router), WETH);
    LidoAdapter adapter = new LidoAdapter(address(book), address(vault), WSTETH, WETH, QUEUE);
    assertEq(address(adapter), expectedAdapter);
    assertEq(address(vault), c.vault);
    assertEq(address(executor), c.executor);
  }

  function test_ForkHistoricalRecoveryPaysActualIssuerCash() public {
    uint256[] memory ids = new uint256[](1);
    ids[0] = 134_829;
    Queue.WithdrawalRequestStatus memory s = Queue(QUEUE).getWithdrawalStatus(ids)[0];
    assertTrue(s.isFinalized);
    assertFalse(s.isClaimed);
    HistoricalReceiptHarness receipt = new HistoricalReceiptHarness(QUEUE, WETH);
    receipt.initialize(ids[0], address(this));
    vm.prank(s.owner);
    IERC721(QUEUE).transferFrom(s.owner, address(receipt), ids[0]);
    receipt.seed(s.amountOfStETH);
    uint256[] memory hints =
      ILidoQueueHistory(QUEUE).findCheckpointHints(ids, 1, ILidoQueueHistory(QUEUE).getLastCheckpointIndex());
    uint256 expected = Queue(QUEUE).getClaimableEther(ids, hints)[0];
    uint256 beforeIssuer = QUEUE.balance;
    uint256 beforeOwner = IERC20(WETH).balanceOf(address(this));
    assertEq(receipt.recover(hints[0]), expected);
    assertEq(receipt.redeem(address(this)), expected);
    assertEq(QUEUE.balance, beforeIssuer - expected);
    assertEq(IERC20(WETH).balanceOf(address(this)), beforeOwner + expected);
    assertEq(receipt.totalSupply(), 0);
  }
}
