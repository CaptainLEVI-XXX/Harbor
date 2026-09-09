// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IHarborValuation} from "src/interfaces/IHarborValuation.sol";
import {HarborClaimGuard} from "src/swapvm/instructions/HarborClaimGuard.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";

/// @title BookPortfolio
/// @notice Bounded public valuation and shared issuer capacity for inventory and receipts.
/// @dev Historical receipt routes never appear in unbounded portfolio loops.
library BookPortfolio {
  error CapacityExceeded();
  error InvalidQuote();
  /// @notice Cursor exceeds the live set or page size is not 1..32.
  error InvalidPage();

  /// @notice Current issuer obligation, sufficient to construct a recovery request without logs.
  struct NativeClaim {
    bytes32 key;
    uint256 route;
    address adapter;
    uint256 issuerId;
    uint256 basis; // WETH wei, retained until final settlement.
    uint256 remaining; // WETH-denominated entitlement, not cash.
    uint256 received; // Attributable cumulative WETH wei.
  }

  /// @notice Read up to 32 live native rights; no issuer, token or valuation calls.
  /// @dev Swap-pop indices are block-local cursors, not persistent claim identifiers.
  function nativeClaims(Accounting.State storage book, RouteConfig[] storage routes, uint256 cursor, uint256 limit)
    public
    view
    returns (NativeClaim[] memory claims, uint256 next)
  {
    uint256 length = book.claims.active.length;
    if (limit == 0 || limit > 32 || cursor > length) revert InvalidPage();
    uint256 size = length - cursor;
    if (size > limit) size = limit;
    claims = new NativeClaim[](size);
    for (uint256 i; i < size; ++i) {
      bytes32 key = book.claims.active[cursor + i];
      ClaimAccounting.Claim storage c = book.claims.claims[key];
      claims[i] =
        NativeClaim(key, c.route, routes[c.route].adapter, book.protocolIds[key], c.basis, c.remaining, c.received);
    }
    next = cursor + size;
  }

  struct Value {
    uint256 inventory;
    uint256 claims;
    uint256 observedAt;
    uint256 policy;
    bool valid;
  }

  /// @notice Verify a receipt's live identity, published factory version and one-unit trade.
  function receiptCheck(
    ClaimMarkets.State storage markets,
    uint256 route,
    bool buy,
    uint256 quantity,
    uint256 cash,
    uint256 version,
    address weth
  ) public view {
    ClaimMarkets.Market storage m = markets.markets[route];
    if (buy && !markets.integrations[m.factory].enabled) revert InvalidQuote();
    address receipt = m.receipt;
    HarborClaimGuard.check(
      receipt,
      m.factory,
      version,
      buy ? receipt : weth,
      buy ? weth : receipt,
      buy ? quantity : cash,
      buy ? cash : quantity
    );
  }

  /// @notice Enforce aggregate and issuer-level budgets independently of signed prices.
  function capacity(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    uint256 nativeRoutes,
    uint256 route,
    bool buy,
    uint256 quantity,
    uint256 cash,
    uint256 available,
    uint256 maxExposure,
    address vault
  ) public view {
    bool claim = markets.markets[route].factory != address(0);
    uint256 source = claim ? markets.markets[route].sourceRoute : route;
    Accounting.Position storage p = book.positions[route];
    Accounting.Position storage parent = book.positions[source];
    ClaimMarkets.Totals storage t = markets.totals[source];
    RouteConfig storage r = routes[source];
    uint256 losses = parent.realizedLosses + t.losses;
    if (buy) {
      uint256 exposure;
      for (uint256 i; i < nativeRoutes; ++i) {
        exposure += Accounting.exposure(book.positions[i]) + markets.totals[i].basis;
      }
      if (
        cash > available || Accounting.exposure(parent) + t.basis + cash > r.maxExposure
          || exposure + cash > maxExposure || parent.purchases + t.purchases + cash > r.maxPurchases
          || losses >= r.lossBudget
      ) revert CapacityExceeded();
      if (claim && (p.shares != 0 || markets.active.length + book.claims.active.length >= 64)) {
        revert CapacityExceeded();
      }
    } else {
      if (
        quantity > p.shares || quantity == 0
          || SafeTransfer.balanceOf(ClaimMarkets.base(markets, routes, route), vault) < p.shares
      ) {
        revert CapacityExceeded();
      }
      uint256 basis = quantity == p.shares ? p.basis : Math.fullMulDiv(p.basis, quantity, p.shares);
      if (basis > cash && (losses >= r.lossBudget || basis - cash > r.lossBudget - losses)) revert CapacityExceeded();
    }
  }

  /// @notice Exact-quantity public observation; claim bids/asks are bounded against its mark.
  /// @dev The observation hash binds issuer, request, receipt and the public policy data.
  function observation(
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    IHarborValuation provider,
    uint256 route,
    uint256 quantity
  ) public view returns (uint256 entitlement, uint256 mark, uint256 time, uint256 policy, bytes32 hash, bool valid) {
    ClaimMarkets.Market storage m = markets.markets[route];
    if (m.factory == address(0)) return provider.inventory(routes[route].base, quantity);
    if (quantity != 1) revert InvalidQuote();
    IHarborClaim c = IHarborClaim(m.receipt);
    uint256 requested = c.entitlement();
    (mark, time, policy, valid) = provider.claim(routes[m.sourceRoute].adapter, m.requestId, requested);
    valid = valid && mark <= requested;
    entitlement = mark;
    hash = keccak256(abi.encode(m.factory, address(c), c.ISSUER(), m.requestId, requested, mark, time, policy));
  }

  /// @notice Mark native inventory, native claims and held receipts exactly once.
  function valuation(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    IHarborValuation provider,
    uint256 nativeRoutes,
    address vault,
    bool stopped
  ) public view returns (Value memory v) {
    v.observedAt = block.timestamp;
    v.valid = !stopped;
    for (uint256 i; i < nativeRoutes; ++i) {
      (uint256 entitlement, uint256 mark, uint256 time, uint256 policy,, bool ok) =
        provider.inventory(routes[i].base, book.positions[i].shares);
      if (i == 0) v.policy = policy;
      v.inventory += mark;
      _merge(v, time, policy, ok && mark <= entitlement);
    }
    for (uint256 i; i < book.claims.active.length; ++i) {
      bytes32 key = book.claims.active[i];
      ClaimAccounting.Claim storage c = book.claims.claims[key];
      (uint256 mark, uint256 time, uint256 policy, bool ok) =
        provider.claim(routes[c.route].adapter, book.protocolIds[key], c.remaining);
      v.claims += mark;
      _merge(v, time, policy, ok && mark <= c.remaining);
    }
    for (uint256 i; i < markets.active.length; ++i) {
      uint256 route = markets.active[i];
      ClaimMarkets.Market storage m = markets.markets[route];
      IHarborClaim c = IHarborClaim(m.receipt);
      if (book.positions[route].shares != 1 || SafeTransfer.balanceOf(address(c), vault) != 1) {
        v.valid = false;
      }
      IHarborClaim.Status status = c.status();
      if (status == IHarborClaim.Status.CASH_READY) {
        uint256 cash = c.recovered();
        v.claims += cash;
        v.valid = v.valid && SafeTransfer.balanceOf(c.WETH(), address(c)) >= cash;
      } else {
        (uint256 mark, uint256 time, uint256 policy, bool ok) =
          provider.claim(routes[m.sourceRoute].adapter, m.requestId, c.entitlement());
        v.claims += mark;
        _merge(
          v,
          time,
          policy,
          ok && mark <= c.entitlement()
            && (status == IHarborClaim.Status.PENDING || status == IHarborClaim.Status.FINALIZED)
        );
      }
    }
  }

  function _merge(Value memory v, uint256 time, uint256 policy, bool valid) private pure {
    if (time < v.observedAt) v.observedAt = time;
    v.valid = v.valid && valid && policy == v.policy;
  }

  /// @notice Detect issuer finalization or permissionless receipt recovery between NAV checkpoints.
  /// @dev Zero for no held receipts. Invalid custody reverts; callers treat this as stale.
  function receiptState(ClaimMarkets.State storage markets, address vault) public view returns (bytes32 hash) {
    for (uint256 i; i < markets.active.length; ++i) {
      IHarborClaim c = IHarborClaim(markets.markets[markets.active[i]].receipt);
      hash =
        keccak256(abi.encode(hash, address(c), c.status(), c.recovered(), SafeTransfer.balanceOf(address(c), vault)));
    }
  }
}
