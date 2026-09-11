// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {IHarborClaimAdapter} from "src/interfaces/IHarborClaimAdapter.sol";
import {InventoryObservation, ClaimObservation, ClaimDomain} from "src/types/ClaimTypes.sol";
import {IHarborValuation} from "src/interfaces/IHarborValuation.sol";
import {IHarborPool} from "src/interfaces/IHarborPool.sol";
import {HarborClaimGuard} from "src/swapvm/instructions/HarborClaimGuard.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";

/// @title BookPortfolio
/// @notice Bounded public valuation and shared issuer capacity for inventory and receipts.
/// @dev Historical receipt routes never appear in unbounded portfolio loops.
library BookPortfolio {
  error SettlementMismatch();

  /// @notice Revalidate the traded right after all token callbacks, without repricing.
  /// @dev Fixed linked code reads the Book's ledgers. Receipt custody/admission
  /// and the exact-quantity issuer observation must still match authorization.
  /// No state changes, caller-selected targets, or cached NAV authority.
  function checkSettlement(
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    uint256 id,
    bool buy,
    uint256 quantity,
    uint256 cash,
    uint256 factoryVersion,
    address cashAsset,
    bytes32 expectedEvidence
  ) public view {
    if (markets.markets[id].factory != address(0)) {
      receiptCheck(markets, id, buy, quantity, cash, factoryVersion, cashAsset);
    }
    (,,,, bytes32 evidence, bool valid) = observation(markets, routes, id, quantity);
    if (!valid || evidence != expectedEvidence) revert SettlementMismatch();
  }

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
    uint256 basis; // settlement-asset raw units, retained until final settlement.
    uint256 remaining; // settlement-asset-denominated entitlement, not cash.
    uint256 received; // Attributable cumulative settlement-asset raw units.
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
    bytes32 evidence;
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
    address cashAsset
  ) public view {
    ClaimMarkets.Market storage m = markets.markets[route];
    if (buy && !markets.integrations[m.factory][m.adapter].enabled) revert InvalidQuote();
    address receipt = m.receipt;
    HarborClaimGuard.check(
      receipt,
      m.factory,
      version,
      buy ? receipt : cashAsset,
      buy ? cashAsset : receipt,
      buy ? quantity : cash,
      buy ? cash : quantity
    );
  }

  /// @notice Enforce aggregate and issuer-level budgets independently of pricing estimates.
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
    uint256 route,
    uint256 quantity
  ) public view returns (uint256 entitlement, uint256 mark, uint256 time, uint256 policy, bytes32 hash, bool valid) {
    ClaimMarkets.Market storage m = markets.markets[route];
    if (m.factory == address(0)) {
      return IHarborValuation(routes[route].adapter).inventory(routes[route].base, quantity);
    }
    if (quantity != 1) revert InvalidQuote();
    // Canonical receipt/adapter/id bindings are immutable after registration.
    // The receipt's entitlement getter calls this same adapter again; read one
    // coherent live observation instead. Neither mark nor status is cached here.
    ClaimObservation memory o = IHarborClaimAdapter(m.adapter).claimState(m.claimId);
    (mark, time, policy, valid) = (o.mark, o.observedAt, 1, o.valid);
    entitlement = o.entitlement;
    valid = valid && entitlement == m.nominal && mark <= entitlement;
    hash = keccak256(abi.encode(m.factory, m.receipt, m.adapter, m.claimId, entitlement, mark, time, policy));
  }

  /// @notice Mark native inventory, native claims and held receipts exactly once.
  function valuation(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    uint256 nativeRoutes,
    address vault,
    bool stopped
  ) public view returns (Value memory v) {
    v.observedAt = block.timestamp;
    v.valid = !stopped;
    address asset = IHarborPool(address(this)).ASSET();
    for (uint256 route; route < nativeRoutes; ++route) {
      address adapter = routes[route].adapter;
      if (IHarborClaimAdapter(adapter).ASSET() != asset) revert InvalidQuote();
      bytes32[] memory ids = _claimIds(book, markets, route, adapter);
      (InventoryObservation memory inv, ClaimObservation[] memory claims) =
        IHarborValuation(adapter).observePortfolio(routes[route].base, book.positions[route].shares, ids);
      if (claims.length != ids.length) revert InvalidQuote();
      v.evidence = keccak256(abi.encode(v.evidence, route, inv.observationHash, book.positions[route].shares));
      for (uint256 i; i < claims.length; ++i) {
        ClaimObservation memory o = claims[i];
        v.evidence = keccak256(abi.encode(v.evidence, ids[i], o.domain, o.status, o.entitlement, o.mark, o.cash));
      }
      v.inventory += inv.mark;
      _merge(
        v,
        inv.observedAt,
        inv.valid && inv.mark <= inv.entitlement
          && SafeTransfer.balanceOf(routes[route].base, vault) >= book.positions[route].shares
      );
      _mergeClaims(v, book, markets, route, vault, claims);
    }
  }

  /// @dev Native claims precede held receipts, each in its live-set order. Book
  /// caps their combined count at 64. Only static calls occur while using these IDs.
  function _claimIds(Accounting.State storage book, ClaimMarkets.State storage markets, uint256 route, address adapter)
    private
    view
    returns (bytes32[] memory ids)
  {
    uint256 count;
    for (uint256 i; i < book.claims.active.length; ++i) {
      if (book.claims.claims[book.claims.active[i]].route == route) ++count;
    }
    for (uint256 i; i < markets.active.length; ++i) {
      if (markets.markets[markets.active[i]].sourceRoute == route) ++count;
    }
    ids = new bytes32[](count);
    uint256 cursor;
    for (uint256 i; i < book.claims.active.length; ++i) {
      bytes32 key = book.claims.active[i];
      if (book.claims.claims[key].route == route) {
        ids[cursor++] = IHarborAdapter(adapter).nativeClaimId(book.protocolIds[key]);
      }
    }
    for (uint256 i; i < markets.active.length; ++i) {
      ClaimMarkets.Market storage m = markets.markets[markets.active[i]];
      if (m.sourceRoute == route) ids[cursor++] = m.claimId;
    }
  }

  /// @dev Consume observations in _claimIds order. Native and tokenized domains
  /// have distinct ownership proofs; an adapter-wide credit is never a pool asset.
  function _mergeClaims(
    Value memory v,
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    uint256 route,
    address vault,
    ClaimObservation[] memory claims
  ) private view {
    uint256 cursor;
    for (uint256 i; i < book.claims.active.length; ++i) {
      ClaimAccounting.Claim storage c = book.claims.claims[book.claims.active[i]];
      if (c.route != route) continue;
      ClaimObservation memory o = claims[cursor++];
      v.claims += o.mark;
      _merge(
        v,
        o.observedAt,
        o.valid && o.domain == ClaimDomain.NATIVE_VAULT && o.entitlement == c.remaining && o.mark <= c.remaining
          && (o.status == IHarborClaim.Status.PENDING || o.status == IHarborClaim.Status.FINALIZED)
      );
    }
    for (uint256 i; i < markets.active.length; ++i) {
      uint256 receiptRoute = markets.active[i];
      ClaimMarkets.Market storage m = markets.markets[receiptRoute];
      if (m.sourceRoute != route) continue;
      ClaimObservation memory o = claims[cursor++];
      v.claims += o.mark;
      _merge(
        v,
        o.observedAt,
        o.valid && o.domain == ClaimDomain.TOKENIZED && o.entitlement == m.nominal && o.mark <= m.nominal
          && o.status != IHarborClaim.Status.CLOSED && book.positions[receiptRoute].shares == 1
          && SafeTransfer.balanceOf(m.receipt, vault) == 1
      );
    }
  }

  /// @dev The marking schema is fixed at admission, not supplied as a per-call policy flag.
  function _merge(Value memory v, uint256 time, bool valid) private pure {
    if (time < v.observedAt) v.observedAt = time;
    v.valid = v.valid && valid;
  }

  /// @notice Live nominal FACE, independent of acquisition cost and discounted NAV.
  /// @dev At most two live inventory conversions plus maintained native/receipt FACE totals;
  /// no per-claim issuer reads or historical scan is needed for this capacity view.
  /// Request/export move the same right between sets. Loss settlement removes
  /// extinguished rights even when recovered cash is zero. CASH_READY receipts
  /// retain their FACE allocation until their cash reaches the vault.
  function face(
    Accounting.State storage book,
    ClaimMarkets.State storage markets,
    RouteConfig[] storage routes,
    uint256 nativeRoutes,
    address vault
  ) public view returns (uint256 total) {
    for (uint256 i; i < nativeRoutes; ++i) {
      uint256 quantity = book.positions[i].shares;
      if (SafeTransfer.balanceOf(routes[i].base, vault) < quantity) revert InvalidQuote();
      (uint256 numerator, uint256 denominator) = IHarborValuation(routes[i].adapter).conversion(routes[i].base);
      if (numerator == 0 || denominator == 0) revert InvalidQuote();
      total += Math.fullMulDiv(quantity, numerator, denominator);
    }
    total += book.nativeClaimsFace + markets.heldFace;
  }
}
