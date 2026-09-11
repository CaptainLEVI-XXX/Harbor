// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";

/// @title BookAccounting
/// @notice Inventory basis, pending exposure and enforceable loss budgets by route.
/// @dev Values are historical cost, not share NAV. No token or issuer calls occur here.
library BookAccounting {
  using ClaimAccounting for ClaimAccounting.State;

  struct Position {
    uint256 shares; // Managed wrapped token raw units.
    uint256 basis; // Warehouse acquisition cost, settlement-asset raw units.
    uint256 pendingBasis; // Cost assigned to live issuer claims, settlement-asset raw units.
    uint256 purchases; // Native lifetime gross purchase debits, settlement-asset raw units; zero for receipt routes.
    uint256 realizedLosses; // Native lifetime losses; receipt losses live only in issuer receipt totals.
    uint256 version; // This position's keeper-intent epoch; also emitted with realizations.
  }

  struct State {
    mapping(uint256 => Position) positions;
    ClaimAccounting.State claims;
    mapping(bytes32 => uint256) protocolIds; // Live inverse IDs needed by valuation/discovery; cleared on closure.
    uint256 nativeClaimsFace; // Outstanding nominal native rights; cash remains in the Vault ledger.
  }

  error InvalidPositionAmount();
  error InsufficientInventory(uint256 available, uint256 requested);

  enum RealizationKind {
    SALE,
    ISSUER_RECOVERY
  }

  /// @notice Final cost and cash result; gains are reconstructed from logs, not stored.
  /// @dev ASSET amounts include purchase fees in basis and exclude sale fees from proceeds.
  /// claimKey is zero for a sale; join its route/version to the same transaction's fill.
  event PositionRealized(
    uint256 indexed route,
    bytes32 indexed claimKey,
    RealizationKind kind,
    uint256 basis,
    uint256 proceeds,
    uint256 positionVersion
  );

  /// @notice Record exact received inventory and gross paid ASSET including the fee.
  function buy(State storage self, uint256 route, uint256 shares, uint256 cost) public {
    if (shares == 0 || cost == 0) revert InvalidPositionAmount();
    Position storage p = self.positions[route];
    p.shares += shares;
    p.basis += cost;
    p.purchases += cost;
    ++p.version;
  }

  /// @notice Remove warehouse shares and realize verified net ASSET revenue.
  /// @return basis Assigned cost rounded down; final removal takes all remaining cost.
  function sell(State storage self, uint256 route, uint256 shares, uint256 revenue) public returns (uint256 basis) {
    Position storage p = self.positions[route];
    basis = _remove(p, shares);
    _realize(p, basis, revenue);
    ++p.version;
    emit PositionRealized(route, bytes32(0), RealizationKind.SALE, basis, revenue, p.version);
  }

  /// @notice Move inventory basis to one externally verified issuer right.
  /// @dev Split requests call this for each actual share allocation, final remainder last.
  function request(State storage self, uint256 route, uint256 shares, bytes32 id, uint256 entitlement)
    public
    returns (uint256 basis)
  {
    Position storage p = self.positions[route];
    basis = _remove(p, shares);
    p.pendingBasis += basis;
    self.claims.create(id, route, basis, entitlement);
    self.nativeClaimsFace += entitlement;
    ++p.version;
  }

  /// @notice Record measured ASSET without treating residual claims as cash.
  /// @dev Real losses are always recorded, even above configured risk budgets.
  /// The boundary stops new buys instead of reverting recovery to conceal a loss.
  function recover(State storage self, bytes32 id, uint256 cash, uint256 remaining) public {
    // Closure clears the payload; cache the route before retiring the live right.
    uint256 route = self.claims.claims[id].route;
    self.nativeClaimsFace -= self.claims.claims[id].remaining - remaining;
    (bool closed, uint256 basis, uint256 receipts) = self.claims.receiveCash(id, cash, remaining);
    Position storage p = self.positions[route];
    if (closed) {
      delete self.protocolIds[id];
      p.pendingBasis -= basis;
      _realize(p, basis, receipts);
    }
    ++p.version;
    if (closed) emit PositionRealized(route, id, RealizationKind.ISSUER_RECOVERY, basis, receipts, p.version);
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
    if (cash < basis) p.realizedLosses += basis - cash;
  }
}
