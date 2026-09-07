// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHarborBook} from "src/interfaces/IHarborBook.sol";

import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";
import {BookState} from "src/book/base/BookState.sol";
import {BookGovernance} from "src/book/base/BookGovernance.sol";
import {BookRedemptions} from "src/book/base/BookRedemptions.sol";
import {BookSettlement} from "src/book/base/BookSettlement.sol";

/// @title HarborBook
/// @notice Immutable pooled-maker Book composed from focused responsibility modules.
/// @dev Governance, issuer lifecycle and SwapVM settlement share exactly one BookState.
/// This concrete contract owns deployment and portfolio views; no proxy initialization.
contract HarborBook is BookGovernance, BookRedemptions, BookSettlement {
  using Accounting for Accounting.State;

  /// @notice Bind the immutable mandate and fixed route universe.
  /// @param c Settlement dependencies, authorities and bounded risk configuration.
  /// @param routes Approved token/adapter pairs; one or two routes only.
  constructor(Config memory c, RouteConfig[] memory routes) BookState(c, routes) {}

  /// @inheritdoc IHarborBook
  function route(uint256 id) external view returns (RouteConfig memory) {
    return _routes[id];
  }

  /// @notice Read inventory cost accounting for one route, not its current NAV.
  /// @param id Approved route index.
  /// @return Position containing wrapped shares and WETH-denominated cost/results.
  function getPosition(uint256 id) external view returns (Accounting.Position memory) {
    return _state.positions[id];
  }

  /// @notice Current persistent portfolio version used to invalidate quotes.
  /// @return Version advanced on material portfolio transitions.
  function portfolioVersion() external view returns (uint256) {
    return _state.version;
  }

  /// @notice Read a tracked issuer right, including closed historical records.
  /// @param adapter Approved adapter that defines the ID namespace.
  /// @param id Issuer-native request ID.
  /// @return Claim whose basis/cash/remaining entitlement are underlying wei.
  function getClaim(address adapter, uint256 id) external view returns (ClaimAccounting.Claim memory) {
    return _state.claims.claims[ClaimAccounting.key(adapter, id)];
  }

  /// @inheritdoc IHarborBook
  function hasManagedPositions() external view returns (bool) {
    if (_state.claims.active.length != 0) return true;
    for (uint256 i; i < _routes.length; ++i) {
      if (_state.positions[i].shares != 0) return true;
    }
    return false;
  }

  /// @inheritdoc IHarborBook
  /// @dev Aggregate at most two inventory marks and 64 live issuer rights.
  /// Marks are public and bounded by entitlement; pending marks do not fund exits.
  function valuation()
    external
    view
    returns (uint256 inventory, uint256 claims, uint256 observedAt, uint256 policyVersion, bool valid)
  {
    observedAt = block.timestamp;
    valid = !stopped;
    for (uint256 i; i < _routes.length; ++i) {
      (uint256 entitlement, uint256 mark, uint256 time, uint256 policy,, bool ok) =
        VALUATION.inventory(_routes[i].base, _state.positions[i].shares);
      inventory += mark;
      if (time < observedAt) observedAt = time;
      if (i == 0) policyVersion = policy;
      valid = valid && ok && policy == policyVersion && mark <= entitlement;
    }
    for (uint256 i; i < _state.claims.active.length; ++i) {
      bytes32 key = _state.claims.active[i];
      ClaimAccounting.Claim storage c = _state.claims.claims[key];
      (uint256 mark, uint256 time, uint256 policy, bool ok) =
        VALUATION.claim(_routes[c.route].adapter, _protocolIds[key], c.remaining);
      claims += mark;
      if (time < observedAt) observedAt = time;
      valid = valid && ok && policy == policyVersion && mark <= c.remaining;
    }
  }
}
