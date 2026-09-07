// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";

/// @title BookAccounting
/// @notice Inventory basis, pending exposure and realized cash results by route.
/// @dev Values are historical cost, not share NAV. No token or issuer calls occur here.
library BookAccounting {
  using ClaimAccounting for ClaimAccounting.State;

  struct Position {
    uint256 shares; // Managed wrapped token raw units.
    uint256 basis; // Warehouse acquisition cost, WETH wei.
    uint256 pendingBasis; // Cost assigned to live issuer claims, WETH wei.
    uint256 purchases; // Lifetime gross purchase debits, WETH wei.
    uint256 realizedGains; // Lifetime positive closed results, WETH wei.
    uint256 realizedLosses; // Lifetime negative closed results; profits do not reset it.
    uint256 version; // Advances on every portfolio transition.
  }

  struct State {
    mapping(uint256 => Position) positions;
    ClaimAccounting.State claims;
    uint256 version;
  }

  error InvalidPositionAmount();
  error InsufficientInventory(uint256 available, uint256 requested);

  /// @notice Record exact received inventory and gross paid WETH including the fee.
  function buy(State storage self, uint256 route, uint256 shares, uint256 cost) internal {
    if (shares == 0 || cost == 0) revert InvalidPositionAmount();
    Position storage p = self.positions[route];
    p.shares += shares;
    p.basis += cost;
    p.purchases += cost;
    _touch(self, p);
  }

  /// @notice Remove warehouse shares and realize verified net WETH revenue.
  /// @return basis Assigned cost rounded down; final removal takes all remaining cost.
  function sell(State storage self, uint256 route, uint256 shares, uint256 revenue) internal returns (uint256 basis) {
    Position storage p = self.positions[route];
    basis = _remove(p, shares);
    _realize(p, basis, revenue);
    _touch(self, p);
  }

  /// @notice Move inventory basis to one externally verified issuer right.
  /// @dev Split requests call this for each actual share allocation, final remainder last.
  function request(State storage self, uint256 route, uint256 shares, bytes32 id, uint256 entitlement)
    internal
    returns (uint256 basis)
  {
    Position storage p = self.positions[route];
    basis = _remove(p, shares);
    p.pendingBasis += basis;
    self.claims.create(id, route, basis, entitlement);
    _touch(self, p);
  }

  /// @notice Record measured WETH without treating residual claims as cash.
  /// @dev Real losses are always recorded, even above configured risk budgets.
  /// The boundary stops new buys instead of reverting recovery to conceal a loss.
  function recover(State storage self, bytes32 id, uint256 cash, uint256 remaining) internal {
    (bool closed, uint256 basis, uint256 receipts) = self.claims.receiveCash(id, cash, remaining);
    Position storage p = self.positions[self.claims.claims[id].route];
    if (closed) {
      p.pendingBasis -= basis;
      _realize(p, basis, receipts);
    }
    _touch(self, p);
  }

  function exposure(Position storage p) internal view returns (uint256) {
    return p.basis + p.pendingBasis;
  }

  function _remove(Position storage p, uint256 shares) private returns (uint256 basis) {
    if (shares == 0) revert InvalidPositionAmount();
    if (shares > p.shares) revert InsufficientInventory(p.shares, shares);
    basis = shares == p.shares ? p.basis : Math.fullMulDiv(p.basis, shares, p.shares);
    p.shares -= shares;
    p.basis -= basis;
  }

  function _realize(Position storage p, uint256 basis, uint256 cash) private {
    if (cash >= basis) p.realizedGains += cash - basis;
    else p.realizedLosses += basis - cash;
  }

  function _touch(State storage self, Position storage p) private {
    ++p.version;
    ++self.version;
  }
}
