// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHarborBook} from "src/interfaces/IHarborBook.sol";

import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {RedemptionAccounting} from "src/libraries/RedemptionAccounting.sol";

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {RouteConfig, Operation, RedeemIntent} from "src/types/HarborTypes.sol";
import {BookState} from "src/book/base/BookState.sol";

/// @title BookRedemptions
/// @notice Inventory-to-issuer-right transitions and measured cash recovery.
/// @dev Pending rights retain acquisition basis and never become spendable cash.
/// Recovery is permissionless, bounded, and independent of fresh quotes or marks.
abstract contract BookRedemptions is BookState {
  using RedemptionAccounting for RedemptionAccounting.State;

  using Accounting for Accounting.State;

  /// @notice Current issuer-request invalidation epoch, distinct from quotes.
  /// @return Epoch used by RedeemIntent replay protection.
  function redemptionEpoch() external view returns (uint256) {
    return _redemptions.epoch;
  }

  /// @notice Whether an issuer intent nonce has been consumed.
  /// @param epoch Request epoch, not quote epoch.
  /// @param nonce Keeper's exact-intent nonce.
  /// @return True after successful consumption; reverted requests do not consume.
  function usedRedemptionNonce(uint256 epoch, uint256 nonce) external view returns (bool) {
    return _redemptions.usedNonce[epoch][nonce];
  }

  /// @notice Convert managed wrapped inventory into verified issuer rights.
  /// @dev Keeper only. Basis moves to pending exposure, not available cash.
  /// Every adapter receipt is checked before recording it; failure rolls back
  /// inventory transfer, issuer request, nonces and all accounting.
  /// @param intent Exact route, amount, versions, deadline and split commitment.
  /// @param amounts One to eight wrapped-share amounts in base-token raw units.
  /// @return requests Verified adapter receipts, one per requested split.
  function requestRedemption(RedeemIntent calldata intent, uint256[] calldata amounts)
    external
    returns (IHarborAdapter.Request[] memory requests)
  {
    if (msg.sender != KEEPER || stopped) revert Unauthorized();
    RouteConfig storage r = _routes[intent.route];
    bytes32 context =
      _redemptions.consume(intent, amounts, address(VAULT), r.adapter, _state.positions[intent.route].version);
    if (intent.shares > _state.positions[intent.route].shares || _state.claims.active.length + amounts.length > 64) {
      revert CapacityExceeded();
    }
    _open(context, Operation.REDEMPTION);
    _route = intent.route;
    _cash = intent.shares;
    IHarborAdapter adapter = IHarborAdapter(r.adapter);
    if (
      adapter.BOOK() != address(this) || adapter.VAULT() != address(VAULT) || adapter.BASE() != r.base
        || adapter.WETH() != WETH
    ) revert InvalidConfiguration();
    uint256 previousBalance = SafeTransfer.balanceOf(r.base, r.adapter);
    VAULT.transferForRedemption(context);
    requests = adapter.request(amounts, previousBalance);
    if (requests.length != amounts.length) revert SettlementMismatch();
    uint256 underlying;
    for (uint256 i; i < requests.length; ++i) {
      IHarborAdapter.Request memory request = requests[i];
      if (request.shares != amounts[i] || request.id == 0) revert SettlementMismatch();
      bytes32 key = ClaimAccounting.key(r.adapter, request.id);
      uint256 basis = _state.request(intent.route, request.shares, key, request.entitlement);
      _protocolIds[key] = request.id;
      underlying += request.entitlement;
      emit RedemptionRequested(context, intent.route, request.id, request.shares, basis, request.entitlement);
    }
    _redemptions.record(intent.route, underlying, intent.minUnderlying, r.maxDailyRedemption);
    VAULT.settleIssuer(context, 0);
    _release();
  }

  /// @inheritdoc IHarborBook
  function redemptionTransfer(bytes32 context)
    external
    view
    returns (address base, address adapter, uint256 amount, uint256 managed)
  {
    if (msg.sender != address(VAULT) || _operation != Operation.REDEMPTION || context != _context) {
      revert Unauthorized();
    }
    return (_routes[_route].base, _routes[_route].adapter, _cash, _state.positions[_route].shares);
  }

  /// @notice Permissionless recovery independent of signer, keeper, CRE and NAV.
  /// @param routeId Fixed approved adapter route.
  /// @param ids One to eight strictly increasing tracked issuer IDs.
  /// @param hints Issuer proof hints, positionally aligned with ids.
  function claimRedemptions(uint256 routeId, uint256[] calldata ids, uint256[] calldata hints) external {
    if (ids.length == 0 || ids.length > 8 || ids.length != hints.length) revert InvalidConfiguration();
    address adapter = _routes[routeId].adapter;
    _open(keccak256(abi.encode(msg.sender, routeId, ids, hints)), Operation.RECOVERY);
    uint256 total;
    for (uint256 i; i < ids.length; ++i) {
      // Strict ordering rejects duplicates before any issuer interaction for that ID.
      if (i != 0 && ids[i] <= ids[i - 1]) revert InvalidConfiguration();
      bytes32 key = ClaimAccounting.key(adapter, ids[i]);
      ClaimAccounting.Claim storage c = _state.claims.claims[key];
      if (!c.exists || c.closed || c.route != routeId) revert InvalidConfiguration();
      uint256 beforeBalance = SafeTransfer.balanceOf(WETH, address(VAULT));
      (uint256 cash, uint256 remaining) = IHarborAdapter(adapter).claim(ids[i], hints[i]);
      if (SafeTransfer.balanceOf(WETH, address(VAULT)) != beforeBalance + cash) revert SettlementMismatch();
      _state.recover(key, cash, remaining);
      total += cash;
      emit RedemptionRecovered(routeId, ids[i], cash, remaining);
    }
    VAULT.settleIssuer(_context, total);
    _release();
  }
}
