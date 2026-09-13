// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {HarborBook} from "src/book/HarborBook.sol";
import {Periphery} from "src/Periphery.sol";
import {DeployHarborNftHoodi} from "script/deploy/DeployHarborNftHoodi.s.sol";
import {DeployHarbor} from "script/deploy/DeployHarbor.s.sol";
import {SeedInventoryHoodi} from "script/seed/SeedInventoryHoodi.s.sol";
import {PopulateEarnHoodi} from "script/seed/PopulateEarnHoodi.s.sol";

import {HoodiFork} from "test/base/HoodiFork.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IWETH} from "@1inch/solidity-utils/contracts/interfaces/IWETH.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {LidoViews} from "src/adapters/lido/LidoViews.sol";
import {ILidoWithdrawalQueue as Queue} from "src/interfaces/ILidoWithdrawalQueue.sol";
import {NftTrade} from "src/types/NftTypes.sol";
import {Trade, RouteConfig, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {PricingCurve, PricingPolicy, PricingParameters} from "src/types/PricingTypes.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";

/// @notice Real issuer custody plus ordinary Aqua/SwapVM trading against the same pool.
/// @dev All deployments/ETH funding are fork-local; no issuer state edits or finalized-claim fabrication.
contract DirectNftForkTest is HoodiFork {
  receive() external payable {}

  function forkBlock() internal pure override returns (uint256) {
    return 3_612_478;
  }

  function test_ForkDeploymentScriptTwoLPsPoliciesAllocationAndFreshNftQuote() public {
    // Public test keys only, confined to this process/fork. Never use real credentials.
    vm.setEnv("HOODI_PRIVATE_KEY", "659918");
    vm.setEnv("LP_A", "1001");
    vm.setEnv("LP_B", "1002");
    vm.setEnv("HOODI_MAX_BASIS_WEI", "1000000000000000000000");
    vm.setEnv("HOODI_FACE_CAP_WEI", "1000000000000000000000");
    vm.setEnv("HOODI_CASH_BUFFER_WEI", "0");
    vm.setEnv("HOODI_MAX_PURCHASES_WEI", "100000000000000000000000");
    vm.setEnv("HOODI_LOSS_BUDGET_WEI", "1000000000000000000000");
    vm.setEnv("HOODI_DAILY_REDEMPTION_WEI", "10000000000000000000000");
    vm.setEnv("HOODI_CAPACITY_KAPPA_WAD", "0");
    vm.setEnv("HOODI_MIN_SEED_WEI", "1000000000000");
    vm.setEnv("HOODI_MIN_REQUEST_SHARES", "1000000000000000000");
    vm.deal(vm.addr(659918), 10 ether);
    vm.deal(vm.addr(1001), 0);
    vm.deal(vm.addr(1002), 0);
    DeployHarborNftHoodi script = new DeployHarborNftHoodi();
    DeployHarbor.Deployment memory d = script.run();
    Periphery periphery = script.setup(address(d.book));
    script.seed(address(d.book), address(periphery), 2500e6, block.timestamp); // Test price, not a live USD quote.
    assertEq(d.vault.balanceOf(vm.addr(1001)), 0.2 ether * 1e6);
    assertEq(d.vault.balanceOf(vm.addr(1002)), 0.2 ether * 1e6);
    assertEq(d.vault.totalAssets(), 0.4 ether);
    assertEq(IERC20(ASSET).balanceOf(address(d.vault)), 0.4 ether);
    assertEq(vm.addr(1001).balance, 0.002 ether);
    assertEq(d.book.pricingParameters(0).validUntil, block.timestamp + 100 days);
    assertEq(d.book.nftParameters(0).validUntil, block.timestamp + 100 days);
    script.verify(address(d.book), address(periphery), address(this));
    vm.expectRevert();
    script.seed(address(d.book), address(periphery), 2500e6, block.timestamp);
    // Mint a fresh ID after policy setup; no per-ID operator transaction.
    vm.deal(address(this), 1 ether);
    (bool ok,) = WSTETH.call{value: 0.1 ether}("");
    assertTrue(ok);
    IERC20(WSTETH).approve(QUEUE, 0.01 ether);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 0.01 ether;
    uint256 id = Queue(QUEUE).requestWithdrawalsWstETH(amounts, address(this))[0];
    script.verifyNft(address(d.book), address(this), id, true);
    IERC721(QUEUE).approve(address(periphery), id);
    periphery.executeNft(
      address(d.book),
      NftTrade(
        address(this),
        address(this),
        0,
        id,
        Side.BUY_BASE,
        AmountMode.EXACT_IN,
        1,
        0,
        block.timestamp + 5 minutes,
        1,
        d.book.configVersion(),
        0
      )
    );
    script.verifyNft(address(d.book), address(this), id, false);

    // Inventory-only continuation: existing LP shares stay unchanged; no buyer consumes seeded choices.
    vm.setEnv("TRADER_A", "2001");
    vm.setEnv("TRADER_B", "2002");
    vm.setEnv("INVENTORY_BOOK", vm.toString(address(d.book)));
    vm.setEnv("INVENTORY_PERIPHERY", vm.toString(address(periphery)));
    SeedInventoryHoodi inventory = new SeedInventoryHoodi();
    inventory.fund(0.05 ether, 0.05 ether, 0.002 ether);
    inventory.stake(true, 0.04 ether, 0.001 ether);
    inventory.stake(false, 0.04 ether, 0.001 ether);
    uint256[] memory lots = new uint256[](2);
    lots[0] = 0.005 ether;
    lots[1] = 0.01 ether;
    uint256[] memory seededIds = inventory.requestNfts(lots);
    uint256 cashBefore = IERC20(ASSET).balanceOf(address(d.vault));
    uint256 aBefore = vm.addr(2001).balance;
    uint256 bBefore = vm.addr(2002).balance;
    inventory.sellToken(0.01 ether, 0.009 ether, 0.2 ether);
    uint256[] memory floors = new uint256[](2);
    floors[0] = 0.004 ether;
    floors[1] = 0.009 ether;
    inventory.sellNfts(seededIds, floors, 0.2 ether);
    inventory.publish();
    assertEq(d.book.getPosition(0).shares, 0.01 ether);
    assertEq(IERC20(WSTETH).balanceOf(address(d.vault)), 0.01 ether);
    uint256 paid = vm.addr(2001).balance - aBefore + vm.addr(2002).balance - bBefore;
    assertEq(IERC20(ASSET).balanceOf(address(d.vault)), cashBefore - paid);
    assertGe(d.vault.tradingCash(0), 0.2 ether);
    assertEq(d.vault.balanceOf(vm.addr(1001)), 0.2 ether * 1e6);
    assertEq(d.vault.balanceOf(vm.addr(1002)), 0.2 ether * 1e6);
    for (uint256 i; i < seededIds.length; ++i) {
      assertEq(IERC721(QUEUE).ownerOf(seededIds[i]), address(d.adapter));
      script.verifyNft(address(d.book), address(this), seededIds[i], false);
    }
    Trade memory ask = Trade(
      address(periphery),
      address(this),
      ASSET,
      WSTETH,
      0,
      Side.SELL_BASE,
      AmountMode.EXACT_OUT,
      0.001 ether,
      0.01 ether,
      block.timestamp + 5 minutes,
      d.book.pricingParameters(0).version,
      d.book.configVersion(),
      d.book.strategyVersion(0)
    );
    (, uint256 offered,) = d.executor.quoteSwap(address(d.book), ask);
    assertEq(offered, 0.001 ether);
    vm.expectRevert(); // The sold IDs no longer belong to Trader B; no duplicate payout.
    inventory.sellNfts(seededIds, floors, 0.2 ether);
    vm.expectRevert(SeedInventoryHoodi.InvalidSeed.selector);
    inventory.sellToken(0.001 ether, 1, cashBefore);
    _exerciseEarnStages(d.book, periphery, seededIds[0]);
  }

  /// @dev Extend the existing real-dependency lifecycle rather than deploy another test suite.
  function _exerciseEarnStages(HarborBook book, Periphery periphery, uint256 id) private {
    PopulateEarnHoodi activity = new PopulateEarnHoodi();
    HarborVault vault = book.VAULT();
    address a = vm.addr(2001);
    address b = vm.addr(2002);
    address lp = vm.addr(1001);
    activity.topUp(true, true, 0.004 ether);
    assertEq(lp.balance, 0.004 ether);
    activity.topUp(true, true, 0.004 ether); // No duplicate transfer once the floor is met.
    assertEq(lp.balance, 0.004 ether);
    uint256 cash = IERC20(ASSET).balanceOf(address(vault));
    uint256 lpShares = vault.balanceOf(lp);
    activity.depositLp(true, 0.001 ether, 1);
    assertEq(IERC20(ASSET).balanceOf(address(vault)), cash + 0.001 ether);
    assertGt(vault.balanceOf(lp), lpShares);

    uint256 beforeBase = book.getPosition(0).shares;
    uint256 traderBase = IERC20(WSTETH).balanceOf(a);
    activity.tradeToken(true, true, true, 0.001 ether, 0.0008 ether, 0.2 ether, 0.001 ether);
    assertEq(book.getPosition(0).shares, beforeBase + 0.001 ether);
    assertEq(IERC20(WSTETH).balanceOf(a), traderBase - 0.001 ether);
    uint256 nativeBefore = a.balance;
    activity.tradeToken(true, true, false, 0.0005 ether, 0.001 ether, 0.2 ether, 0.001 ether);
    assertEq(a.balance, nativeBefore + 0.0005 ether);
    traderBase = IERC20(WSTETH).balanceOf(a);
    activity.tradeToken(true, false, false, 0.0005 ether, 0.001 ether, 0.2 ether, 0.001 ether);
    assertEq(IERC20(WSTETH).balanceOf(a), traderBase + 0.0005 ether);
    nativeBefore = a.balance;
    activity.tradeToken(true, false, true, 0.0005 ether, 0.0003 ether, 0.2 ether, 0.001 ether);
    assertEq(a.balance, nativeBefore - 0.0005 ether);
    vm.expectRevert(SeedInventoryHoodi.InvalidSeed.selector);
    activity.tradeToken(true, false, false, 0.0005 ether, 0.001 ether, 0.2 ether, 1 ether);

    activity.tradeNft(true, false, false, id, 0.01 ether, 0.2 ether);
    assertEq(IERC721(QUEUE).ownerOf(id), a);
    activity.tradeNft(true, true, false, id, 0.003 ether, 0.2 ether);
    assertEq(IERC721(QUEUE).ownerOf(id), book.route(0).adapter);
    activity.tradeNft(false, false, true, id, 0.01 ether, 0.2 ether);
    assertEq(IERC721(QUEUE).ownerOf(id), b);
    activity.tradeNft(false, true, true, id, 0.003 ether, 0.2 ether);
    assertEq(IERC721(QUEUE).ownerOf(id), book.route(0).adapter);
    uint256[] memory pendingId = new uint256[](1);
    pendingId[0] = id;
    vm.expectRevert(SeedInventoryHoodi.InvalidSeed.selector);
    activity.recoverIssuer(pendingId); // No test-only finalized state or made-up recovery.

    uint256 requested = 1e20;
    activity.requestExit(true, requested);
    assertEq(vault.pendingRedeemRequest(0, lp), requested);
    vm.expectRevert(SeedInventoryHoodi.InvalidSeed.selector);
    activity.requestExit(true, requested); // Existing pending request cannot be blindly repeated.
    activity.fundExits();
    assertEq(vault.pendingRedeemRequest(0, lp), 0);
    uint256 payout = vault.maxWithdraw(lp);
    assertGt(payout, 0);
    nativeBefore = lp.balance;
    activity.claimExit(true, payout);
    assertEq(lp.balance, nativeBefore + payout);
    assertEq(vault.maxWithdraw(lp), 0);
    assertEq(IERC20(ASSET).balanceOf(lp), 0); // Claim arrived as ETH, not WETH.
    vm.expectRevert(SeedInventoryHoodi.InvalidSeed.selector);
    activity.claimExit(true, payout);

    cash = IERC20(ASSET).balanceOf(address(vault));
    beforeBase = book.getPosition(0).shares;
    activity.requestIssuer(0.001 ether, 0.0008 ether, 4242, 0.001 ether);
    assertEq(book.getPosition(0).shares, beforeBase - 0.001 ether);
    assertEq(IERC20(ASSET).balanceOf(address(vault)), cash); // Pending entitlement is not new cash.
    assertTrue(book.usedRedemptionNonce(book.redemptionEpoch(), 4242));
    activity.checkpoint();
    (,,, bool valid,) = vault.accountingStatus();
    assertTrue(valid);
    assertEq(IERC20(ASSET).balanceOf(address(periphery)), 0);
    activity.publish();
  }

  function test_ForkFreshIdsWithoutAdmissionAndSharedTokenTrading() public {
    HarborExecutor executor = new HarborExecutor(ROUTER_ADDRESS, address(this));
    // The adapter retains its legacy factory binding, but this path never wraps or admits an ID.
    HarborClaimFactory factory = new HarborClaimFactory(ASSET, address(this), 1 days);
    uint64 nonce = vm.getNonce(address(this));
    address expectedAdapter = vm.computeCreateAddress(address(this), nonce + 2);
    HarborBook.Config memory c;
    c.vault = vm.computeCreateAddress(address(this), nonce + 1);
    c.executor = address(executor);
    c.asset = ASSET;
    c.aqua = AQUA;
    c.router = ROUTER_ADDRESS;
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
    HarborBook book = new HarborBook(c, routes);
    HarborVault vault = new HarborVault(ASSET, address(book), 60, 1e12, 1e6);
    LidoAdapter adapter = new LidoAdapter(
      address(book),
      address(vault),
      WSTETH,
      ASSET,
      QUEUE,
      LidoViews.Config(address(factory), address(this), address(this), 60, 1 days)
    );
    assertEq(address(adapter), expectedAdapter);
    executor.registerPool(address(book));
    uint256 time = block.timestamp;
    adapter.publish(1e18, 1e18, time, time + 60, 1);
    book.configureNfts(0, PricingPolicy(0.95e18, 1e18, 0.005e18, 0.005e18, 0, 0));
    book.publishNfts(0, PricingParameters(0.975e18, time, time + 60, 1, book.configVersion()));
    vm.deal(address(this), 6 ether);
    IWETH(ASSET).deposit{value: 3 ether}();
    IERC20(ASSET).approve(address(vault), 3 ether);
    vault.checkpointValuation();
    vault.deposit(3 ether, address(this));
    (bool ok,) = WSTETH.call{value: 1 ether}("");
    assertTrue(ok);
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = 0.1 ether;
    amounts[1] = 0.2 ether;
    IERC20(WSTETH).approve(QUEUE, 0.3 ether);
    uint256[] memory ids = Queue(QUEUE).requestWithdrawalsWstETH(amounts, address(this));
    IERC721(QUEUE).setApprovalForAll(address(adapter), true);
    for (uint256 i; i < ids.length; ++i) {
      NftTrade memory t = NftTrade(
        address(this),
        address(this),
        0,
        ids[i],
        Side.BUY_BASE,
        AmountMode.EXACT_IN,
        1,
        0,
        time + 60,
        1,
        book.configVersion(),
        0
      );
      FillAmounts memory bid = book.quoteNft(t);
      uint256 cash = IERC20(ASSET).balanceOf(address(this));
      book.executeNft(t);
      assertEq(IERC721(QUEUE).ownerOf(ids[i]), address(adapter));
      assertEq(IERC20(ASSET).balanceOf(address(this)), cash + bid.traderOut);
    }
    (BookPortfolio.NativeClaim[] memory held,) = book.nftInventory(0, 32);
    assertEq(held.length, 2);
    assertEq(held[0].issuerId, ids[0]);
    uint256 face = book.faceExposure();
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), IERC20(ASSET).balanceOf(address(vault)) + face);
    address buyer = address(0xb0b);
    IWETH(ASSET).deposit{value: 0.1 ether}(); // Separate buyer funding covers spread and fees.
    IERC20(ASSET).transfer(buyer, 0.3 ether);
    vm.startPrank(buyer);
    IERC20(ASSET).approve(address(book), 0.3 ether);
    book.executeNft(
      NftTrade(
        buyer,
        buyer,
        0,
        ids[0],
        Side.SELL_BASE,
        AmountMode.EXACT_OUT,
        1,
        0.3 ether,
        time + 60,
        1,
        book.configVersion(),
        1
      )
    );
    vm.stopPrank();
    assertEq(IERC721(QUEUE).ownerOf(ids[0]), buyer);
    // Only ordinary fungible assets require an Aqua strategy.
    vault.refreshStrategy(0);
    book.configurePricing(0, PricingPolicy(0.95e18, 1e18, 0.01e18, 0.01e18, 0, 0));
    book.publishPricing(0, PricingParameters(1e18, time, time + 60, 1, book.configVersion()));
    IERC20(WSTETH).approve(address(executor), 0.1 ether);
    executor.execute(
      address(book),
      Trade(
        address(this),
        address(this),
        WSTETH,
        ASSET,
        0,
        Side.BUY_BASE,
        AmountMode.EXACT_IN,
        0.1 ether,
        0,
        time + 60,
        1,
        book.configVersion(),
        book.strategyVersion(0)
      )
    );
    assertEq(book.getPosition(0).shares, 0.1 ether);
    assertGt(book.faceExposure(), book.getClaim(address(adapter), ids[1]).remaining);
    // The same original NFT can round-trip through native ETH settlement.
    // No receipt deployment, per-ID policy, or new Aqua allocation is needed.
    Periphery periphery = new Periphery(ASSET, address(executor));
    vm.deal(buyer, 1 ether);
    NftTrade memory nativeTrade = NftTrade(
      buyer, buyer, 0, ids[1], Side.SELL_BASE, AmountMode.EXACT_OUT, 1, 0.5 ether, time + 60, 1, book.configVersion(), 1
    );
    FillAmounts memory quote = book.quoteNft(nativeTrade);
    vm.prank(buyer);
    periphery.executeNft{value: 0.5 ether}(address(book), nativeTrade);
    assertEq(buyer.balance, 1 ether - quote.traderIn);
    assertEq(IERC721(QUEUE).ownerOf(ids[1]), buyer);
    nativeTrade.side = Side.BUY_BASE;
    nativeTrade.mode = AmountMode.EXACT_IN;
    nativeTrade.limitAmount = 0;
    nativeTrade.generation = 2;
    quote = book.quoteNft(nativeTrade);
    uint256 beforeEth = buyer.balance;
    vm.startPrank(buyer);
    IERC721(QUEUE).approve(address(periphery), ids[1]);
    periphery.executeNft(address(book), nativeTrade);
    vm.stopPrank();
    assertEq(buyer.balance, beforeEth + quote.traderOut);
    assertEq(IERC721(QUEUE).ownerOf(ids[1]), address(adapter));
    assertEq(IERC20(ASSET).balanceOf(address(periphery)), 0);
    assertEq(IERC20(ASSET).allowance(address(periphery), address(book)), 0);
    assertEq(address(periphery).balance, 0);
  }
}
