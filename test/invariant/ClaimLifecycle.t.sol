// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {BookAccounting as Ledger} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";

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
    _state.recover(g.key, cash, 0);
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
      assertEq(p.realizedGains, g.gains);
      assertEq(p.realizedLosses, g.losses);
      ClaimAccounting.Claim storage c = _state.claims.claims[g.key];
      assertEq(c.remaining, g.remaining);
      assertEq(c.received, g.received);
      if (g.key != 0) {
        assertTrue(c.exists);
        assertEq(c.closed, g.remaining == 0);
        assertEq(c.basis, 90);
      }
      if (g.remaining != 0) ++active;
    }
    assertEq(_state.claims.active.length, active);
  }
}

contract ClaimLifecycleInvariantTest is Test {
  ClaimLifecycleHandler private handler;

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
  }

  function invariant_PartialReceiptsDoNotRetireCostUntilRightsClose() public view {
    handler.assertLedger();
  }

  function afterInvariant() public view {
    assertGt(handler.partials(), 0);
    assertGt(handler.closures(), 0);
  }
}
