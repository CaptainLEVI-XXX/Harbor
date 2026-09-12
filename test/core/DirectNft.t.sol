// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/base/IssuerFixture.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {Trade, FillAmounts, Side, AmountMode} from "src/types/HarborTypes.sol";
import {NftTrade} from "src/types/NftTypes.sol";
import {PricingPolicy, PricingParameters} from "src/types/PricingTypes.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Periphery} from "src/Periphery.sol";

contract NftNativeCaller {
  Periphery immutable periphery;
  address immutable book;
  bool public blocked;
  bool internal reject;

  constructor(Periphery p, address b) {
    periphery = p;
    book = b;
  }

  function sell(address issuer, NftTrade calldata t, bool fail) external {
    reject = fail;
    IERC721(issuer).approve(address(periphery), t.tokenId);
    periphery.executeNft(book, t);
  }

  receive() external payable {
    require(!reject, "ETH rejected");
    try periphery.deposit{value: 1}(book, 0) {
      revert("reentry passed");
    } catch (bytes memory reason) {
      blocked = bytes4(reason) == bytes4(keccak256("Reentrancy()"));
    }
  }
}

contract NftBuyer is IERC721Receiver {
  HarborBook immutable book;
  bool public blocked;
  bool public reject;

  constructor(HarborBook b) {
    book = b;
  }

  function buy(NftTrade calldata t, bool fail) external {
    reject = fail;
    IERC20(book.ASSET()).approve(address(book), t.limitAmount);
    book.executeNft(t);
  }

  function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
    require(!reject, "receiver rejected");
    try book.quoteNft(
      NftTrade(
        address(this), address(this), 0, 1, Side.SELL_BASE, AmountMode.EXACT_OUT, 1, 5 ether, block.timestamp, 1, 1, 0
      )
    ) {
      revert("read lock bypassed");
    } catch {
      blocked = true;
    }
    return IERC721Receiver.onERC721Received.selector;
  }
}

contract DirectNftTest is IssuerFixture {
  function test_PeripheryFourModesDonationIsolationAndCallerBinding() public {
    Periphery p = new Periphery(address(weth), address(executor));
    vm.deal(address(weth), 100 ether);
    vm.deal(bob, 10 ether);
    weth.mint(address(p), 7);
    vm.deal(address(p), 11);
    uint256 id = _externalId(1 ether);
    NftTrade memory t = _intentNft(id, true);
    vm.prank(bob);
    vm.expectRevert(Periphery.InvalidIntent.selector);
    p.executeNft(address(book), t);
    vm.prank(trader); // Approval to adapter is not approval to Periphery.
    vm.expectRevert();
    p.executeNft(address(book), t);
    for (uint256 i; i < 4; ++i) {
      bool buy = i % 2 == 0;
      t = _intentNft(id, buy);
      if (i == 2) t.trader = t.receiver = bob;
      FillAmounts memory q = book.quoteNft(t);
      if (i >= 2) {
        t.mode = buy ? AmountMode.EXACT_OUT : AmountMode.EXACT_IN;
        t.amountSpecified = buy ? q.traderOut : q.traderIn;
        t.limitAmount = 1;
      }
      address actor = t.trader;
      uint256 beforeEth = actor.balance;
      vm.startPrank(actor);
      if (buy) queue.approve(address(p), id);
      uint256 budget = buy ? 0 : t.mode == AmountMode.EXACT_IN ? t.amountSpecified : t.limitAmount;
      (uint256 input, uint256 output) = p.executeNft{value: budget}(address(book), t);
      vm.stopPrank();
      assertEq(input, q.traderIn);
      assertEq(output, q.traderOut);
      assertEq(actor.balance, buy ? beforeEth + output : beforeEth - input);
      assertEq(queue.ownerOf(id), buy ? address(adapter) : actor);
      assertEq(weth.balanceOf(address(p)), 7);
      assertEq(address(p).balance, 11);
      assertEq(weth.allowance(address(p), address(book)), 0);
    }
  }

  function test_PeripheryNativePayoutRollbackAndReentrancy() public {
    Periphery p = new Periphery(address(weth), address(executor));
    vm.deal(address(weth), 100 ether);
    NftNativeCaller caller = new NftNativeCaller(p, address(book));
    uint256 id = _externalId(1 ether);
    vm.prank(trader);
    queue.transferFrom(trader, address(caller), id);
    NftTrade memory t = _intentNft(id, true);
    t.trader = t.receiver = address(caller);
    uint256 beforeCash = weth.balanceOf(address(vault));
    vm.expectRevert();
    caller.sell(address(queue), t, true);
    assertEq(queue.ownerOf(id), address(caller));
    assertEq(weth.balanceOf(address(vault)), beforeCash);
    assertEq(book.nftGeneration(0, id), 0);
    caller.sell(address(queue), t, false);
    assertTrue(caller.blocked());
    assertEq(queue.ownerOf(id), address(adapter));
    assertEq(weth.balanceOf(address(p)), 0);
    assertEq(address(p).balance, 0);
  }

  function setUp() public override {
    super.setUp();
    weth.mint(bob, 10 ether);
    book.configureNfts(0, PricingPolicy(0.95e18, 1e18, 0.005e18, 0.005e18, 0, 0));
    book.publishNfts(0, PricingParameters(0.975e18, block.timestamp, block.timestamp + 60, 1, book.configVersion()));
    vm.prank(bob);
    weth.approve(address(book), type(uint256).max);
  }

  function _externalId(uint256 amount) internal returns (uint256 id) {
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    vm.startPrank(trader);
    bases[0].approve(address(queue), amount);
    id = queue.requestWithdrawalsWstETH(amounts, trader)[0];
    queue.approve(address(adapter), id);
    vm.stopPrank();
  }

  function _intentNft(uint256 id, bool buy) internal view returns (NftTrade memory) {
    return NftTrade(
      buy ? trader : bob,
      buy ? trader : bob,
      0,
      id,
      buy ? Side.BUY_BASE : Side.SELL_BASE,
      buy ? AmountMode.EXACT_IN : AmountMode.EXACT_OUT,
      1,
      buy ? 0 : 5 ether,
      block.timestamp + 60,
      book.nftParameters(0).version,
      book.configVersion(),
      book.nftGeneration(0, id)
    );
  }

  function _sellId(uint256 id) internal returns (FillAmounts memory a) {
    NftTrade memory t = _intentNft(id, true);
    a = book.quoteNft(t);
    uint256 nominal = adapter.nftObservation(id).nominal;
    assertApproxEqAbs(a.routerOut, nominal * 97 / 100, 1);
    assertEq(a.fee, a.routerOut * 10 / 10_000);
    uint256 beforeTrader = weth.balanceOf(trader);
    uint256 beforeFee = weth.balanceOf(address(0xfee));
    vm.prank(trader);
    book.executeNft(t);
    assertEq(weth.balanceOf(trader), beforeTrader + a.traderOut);
    assertEq(weth.balanceOf(address(0xfee)), beforeFee + a.fee);
  }

  function test_TwoFreshIdsOnePolicyFourModesAndInventory() public {
    uint256 first = _externalId(1 ether);
    uint256 second = _externalId(2 ether); // Minted after policy, no per-ID registration.
    _sellId(first);
    _sellId(second);
    (BookPortfolio.NativeClaim[] memory held, uint256 next) = book.nftInventory(0, 32);
    assertEq(held.length, 2);
    assertEq(next, 2);
    assertEq(held[0].issuerId, first);
    assertEq(held[1].issuerId, second);
    assertEq(book.faceExposure(), 3.6 ether);
    NftTrade memory t = _intentNft(first, false);
    FillAmounts memory ask = book.quoteNft(t);
    vm.prank(bob);
    book.executeNft(t);
    assertEq(queue.ownerOf(first), bob);
    vm.prank(bob);
    queue.approve(address(adapter), first);
    t = _intentNft(first, true);
    t.trader = t.receiver = bob;
    FillAmounts memory bid = book.quoteNft(t);
    t.mode = AmountMode.EXACT_OUT;
    t.amountSpecified = bid.traderOut;
    t.limitAmount = 1;
    vm.prank(bob);
    book.executeNft(t); // Same original NFT can be acquired again.
    t = _intentNft(first, false);
    ask = book.quoteNft(t);
    t.mode = AmountMode.EXACT_IN;
    t.amountSpecified = ask.traderIn;
    t.limitAmount = 1;
    vm.prank(bob);
    book.executeNft(t);
    assertEq(queue.ownerOf(first), bob);
    assertEq(book.faceExposure(), 2.4 ether);
    (held,) = book.nftInventory(0, 32);
    assertEq(held.length, 1);
    assertEq(held[0].issuerId, second);
    assertEq(book.nftParameters(0).version, 1);
    assertEq(book.nftGeneration(0, first), 4);
    // The very same Book also executes ordinary inventory through Aqua/SwapVM.
    (Trade memory ordinary,) = _quote(0, Side.BUY_BASE, AmountMode.EXACT_IN, 0.1 ether);
    vm.prank(trader);
    executor.execute(address(book), ordinary);
    assertEq(book.getPosition(0).shares, 0.1 ether);
    assertEq(book.faceExposure(), 2.52 ether);
    // No manual checkpoint between the trade and the next LP issuance.
    // Live backing includes the remaining NFT and the ordinary token inventory.
    uint256 liveNav = weth.balanceOf(address(vault)) + 2.52 ether;
    uint256 expectedShares = uint256(0.1 ether) * (vault.totalSupply() + 1e6) / (liveNav + 1);
    assertGt(vault.maxDeposit(bob), 0);
    assertEq(vault.previewDeposit(0.1 ether), expectedShares);
    vm.startPrank(bob);
    weth.approve(address(vault), 0.1 ether);
    assertEq(vault.deposit(0.1 ether, bob), expectedShares);
    vm.stopPrank();
    assertEq(vault.totalAssets(), liveNav + 0.1 ether);
  }

  function test_NavUsesIndependentMarksThenActualRecoveryAndLoss() public {
    uint256 id = _externalId(1 ether);
    FillAmounts memory a = _sellId(id);
    assertEq(queue.ownerOf(id), address(adapter));
    assertEq(weth.balanceOf(address(vault)), 20 ether - a.routerOut);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 20 ether - a.routerOut + 1.2 ether);
    uint256 nav = vault.totalAssets();
    book.publishNfts(0, PricingParameters(0.95e18, block.timestamp, block.timestamp + 60, 2, book.configVersion()));
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), nav); // A cheaper bid does not change NAV.
    adapter.publish(1e18, 0.9e18, block.timestamp, block.timestamp + 60, adapter.version() + 1);
    (,, bool fresh) = vault.valuationIdentity();
    assertFalse(fresh);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 20 ether - a.routerOut + 1.08 ether);
    queue.setFinalized(id, 0.8 ether);
    NftTrade memory finalized = _intentNft(id, false);
    vm.expectRevert();
    book.quoteNft(finalized);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 20 ether - a.routerOut + 0.8 ether);
    _claim(id);
    vault.checkpointValuation();
    assertEq(vault.totalAssets(), 20 ether - a.routerOut + 0.8 ether);
    assertEq(book.faceExposure(), 0);
    assertEq(book.getPosition(0).pendingBasis, 0);
    assertEq(book.getPosition(0).realizedLosses, a.routerOut - 0.8 ether);
    (BookPortfolio.NativeClaim[] memory held,) = book.nftInventory(0, 32);
    assertEq(held.length, 0);
    vm.expectRevert();
    _claim(id);
  }

  function test_OwnerApprovalStaleGenerationAndExitPriority() public {
    uint256 id = _externalId(1 ether);
    NftTrade memory t = _intentNft(id, true);
    vm.prank(bob);
    vm.expectRevert();
    book.executeNft(t);
    vm.prank(trader);
    queue.approve(address(0), id);
    vm.prank(trader);
    vm.expectRevert();
    book.executeNft(t);
    assertEq(queue.ownerOf(id), trader);
    vm.prank(trader);
    queue.approve(address(adapter), id);
    _sellId(id);
    vm.prank(trader);
    vm.expectRevert();
    book.executeNft(t);
    vault.checkpointValuation();
    vm.prank(alice);
    vault.requestRedeem(1e24, alice, alice);
    uint256 next = _externalId(1 ether);
    t = _intentNft(next, true);
    vm.expectRevert();
    book.quoteNft(t);
    assertEq(queue.ownerOf(next), trader);
    assertEq(vault.tradingCash(0), 0);
  }

  function test_NftReceiverFailureRollsBackCashAndReadLock() public {
    uint256 id = _externalId(1 ether);
    _sellId(id);
    NftBuyer buyer = new NftBuyer(book);
    weth.mint(address(buyer), 5 ether);
    NftTrade memory t = _intentNft(id, false);
    t.trader = t.receiver = address(buyer);
    uint256 cash = weth.balanceOf(address(vault));
    vm.expectRevert();
    buyer.buy(t, true);
    assertEq(weth.balanceOf(address(buyer)), 5 ether);
    assertEq(weth.balanceOf(address(vault)), cash);
    assertEq(queue.ownerOf(id), address(adapter));
    buyer.buy(t, false);
    assertTrue(buyer.blocked());
    assertEq(queue.ownerOf(id), address(buyer));
  }
}
