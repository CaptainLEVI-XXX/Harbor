// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BookAccounting as Ledger} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {RealizationLogs} from "test/base/RealizationLogs.sol";
import {RedemptionMarketFixture} from "test/base/RedemptionMarketFixture.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Side, AmountMode} from "src/types/HarborTypes.sol";

/// @notice Synthetic partial-right semantics, separate from Lido's all-or-nothing claim.
contract ClaimLifecycleHandler is Test {
  using Ledger for Ledger.State;
  Ledger.State private _state;

  struct Ghost {
    bytes32 key;
    uint256 remaining;
    uint256 received;
    uint256 purchases;
    uint256 gains;
    uint256 losses;
    uint256 eventGains;
  }
  Ghost[2] private _ghosts;
  uint256 private _next;
  uint256 public partials;
  uint256 public closures;

  function request(uint8 which) external {
    uint256 route = which % 2;
    Ghost storage g = _ghosts[route];
    if (g.remaining != 0) return;
    g.key = ClaimAccounting.key(address(uint160(route + 1)), ++_next);
    g.remaining = 100;
    g.received = 0;
    g.purchases += 90;
    _state.buy(route, 100, 90);
    _state.request(route, 100, g.key, 100);
  }

  function receivePartial(uint8 which, uint8 releaseSeed, uint8 paymentSeed) external {
    uint256 route = which % 2;
    Ghost storage g = _ghosts[route];
    if (g.remaining < 2) return;
    uint256 released = bound(releaseSeed, 1, g.remaining - 1);
    uint256 cash = bound(paymentSeed, 0, released);
    g.remaining -= released;
    g.received += cash;
    _state.recover(g.key, cash, g.remaining);
    ++partials;
  }

  function close(uint8 which, uint8 seed) external {
    uint256 route = which % 2;
    Ghost storage g = _ghosts[route];
    if (g.remaining == 0) return;
    uint256 cash = bound(seed, 0, g.remaining);
    g.received += cash;
    g.remaining = 0;
    if (g.received >= 90) g.gains += g.received - 90;
    else g.losses += 90 - g.received;
    vm.recordLogs();
    _state.recover(g.key, cash, 0);
    (uint256 gains,, uint256 count) = RealizationLogs.totals(vm.getRecordedLogs(), address(this), route);
    assertEq(count, 1);
    g.eventGains += gains;
    ++closures;
  }

  function assertLedger() external view {
    uint256 active;
    for (uint256 i; i < 2; ++i) {
      Ghost storage g = _ghosts[i];
      Ledger.Position storage p = _state.positions[i];
      assertEq(p.shares, 0);
      assertEq(p.basis, 0);
      assertEq(p.pendingBasis, g.remaining != 0 ? 90 : 0);
      assertEq(p.purchases, g.purchases);
      assertEq(g.eventGains, g.gains);
      assertEq(p.realizedLosses, g.losses);
      ClaimAccounting.Claim storage c = _state.claims.claims[g.key];
      assertEq(c.remaining, g.remaining);
      assertEq(c.received, g.remaining == 0 ? 0 : g.received);
      if (g.key != 0) {
        assertTrue(c.exists);
        assertEq(c.closed, g.remaining == 0);
        assertEq(c.basis, g.remaining == 0 ? 0 : 90);
      }
      if (g.remaining != 0) ++active;
    }
    assertEq(_state.claims.active.length, active);
    assertEq(_state.nativeClaimsFace, _ghosts[0].remaining + _ghosts[1].remaining);
  }
}

/// @notice Small real-contract state machine; issuer finalization alone is synthetic.
contract ClaimCustodyHandler is RedemptionMarketFixture {
  struct Right {
    uint256 issuerId;
    uint256 route;
    address receipt;
    uint256 nominal;
    uint256 payout;
    bool native;
    bool pooled;
    bool collected;
    bool closed;
  }
  Right[] private _rights;
  uint256 public paid;
  uint256 public exported;
  uint256 private _expectedVaultCash;

  function initialize() external {
    setUp();
    _expectedVaultCash = weth.balanceOf(address(vault));
  }

  function create(uint8 seed) external {
    if (_rights.length >= 8) return;
    Right memory r;
    r.nominal = 0.0012 ether;
    r.native = seed % 3 == 0;
    r.pooled = seed % 3 != 1;
    if (r.native) {
      r.issuerId = _request(0.001 ether);
    } else {
      (r.route, r.issuerId, r.receipt) = _externalMarket(0.001 ether);
      if (r.pooled) {
        _tradeClaim(r.route, Side.BUY_BASE, AmountMode.EXACT_IN);
        _expectedVaultCash -= r.nominal * 97 / 100;
      }
    }
    _rights.push(r);
  }

  function exportNative(uint8 index) external {
    if (_rights.length == 0) return;
    Right storage r = _rights[index % _rights.length];
    if (!r.native || r.closed) return;
    r.route = book.exportClaim(0, r.issuerId, address(factory));
    r.receipt = book.route(r.route).base;
    r.native = false;
    ++exported;
  }

  function collect(uint8 index, uint8 recovery) external {
    if (_rights.length == 0) return;
    Right storage r = _rights[index % _rights.length];
    if (r.closed || r.collected) return;
    r.payout = r.nominal * (uint256(recovery) % 101) / 100;
    queue.setFinalized(r.issuerId, r.payout);
    if (r.native) {
      _claim(r.issuerId);
      _expectedVaultCash += r.payout;
      r.closed = true;
      ++paid;
    } else {
      IHarborClaim(r.receipt).recover(abi.encode(uint256(1)));
    }
    r.collected = true;
  }

  function redeem(uint8 index) external {
    if (_rights.length == 0) return;
    Right storage r = _rights[index % _rights.length];
    if (r.closed || !r.collected || r.native) return;
    if (r.pooled) {
      book.recoverClaim(r.route, "");
      _expectedVaultCash += r.payout;
    } else {
      uint256 beforeCash = weth.balanceOf(trader);
      vm.prank(trader);
      IHarborClaim(r.receipt).redeem(trader);
      assertEq(weth.balanceOf(trader), beforeCash + r.payout);
    }
    r.closed = true;
    ++paid;
  }

  function assertCustody() external view {
    uint256 credit;
    uint256 face = book.getPosition(0).shares * 12 / 10;
    for (uint256 i; i < _rights.length; ++i) {
      Right storage r = _rights[i];
      if (!r.closed && r.pooled) face += r.nominal;
      if (!r.native) {
        assertEq(IERC20(r.receipt).totalSupply(), r.closed ? 0 : 1);
        assertEq(IERC20(r.receipt).balanceOf(r.pooled ? address(vault) : trader), r.closed ? 0 : 1);
        assertEq(factory.receiptOf(address(adapter), adapter.nativeClaimId(r.issuerId)), r.receipt);
        if (r.collected && !r.closed) credit += r.payout;
      }
    }
    assertEq(book.faceExposure(), face);
    assertEq(adapter.totalClaimCash(), credit);
    assertEq(weth.balanceOf(address(adapter)), credit);
    assertEq(weth.balanceOf(address(vault)), _expectedVaultCash);
    assertTrue(book.isIdle());
  }
}

contract ClaimLifecycleInvariantTest is Test {
  ClaimLifecycleHandler private handler;
  ClaimCustodyHandler private custody;

  function setUp() public {
    handler = new ClaimLifecycleHandler();
    handler.request(0);
    handler.request(1);
    handler.receivePartial(0, 40, 30);
    handler.close(1, 0);
    bytes4[] memory selectors = new bytes4[](3);
    selectors[0] = handler.request.selector;
    selectors[1] = handler.receivePartial.selector;
    selectors[2] = handler.close.selector;
    targetContract(address(handler));
    targetSelector(FuzzSelector(address(handler), selectors));
    custody = new ClaimCustodyHandler();
    custody.initialize();
    custody.create(0);
    custody.exportNative(0);
    custody.collect(0, 99);
    custody.redeem(0);
    custody.create(1);
    custody.collect(1, 80);
    custody.redeem(1);
    selectors = new bytes4[](4);
    selectors[0] = custody.create.selector;
    selectors[1] = custody.exportNative.selector;
    selectors[2] = custody.collect.selector;
    selectors[3] = custody.redeem.selector;
    targetContract(address(custody));
    targetSelector(FuzzSelector(address(custody), selectors));
  }

  function invariant_PartialReceiptsDoNotRetireCostUntilRightsClose() public view {
    handler.assertLedger();
    custody.assertCustody();
  }

  function afterInvariant() public view {
    assertGt(handler.partials(), 0);
    assertGt(handler.closures(), 0);
    assertGt(custody.paid(), 0);
    assertGt(custody.exported(), 0);
  }
}
