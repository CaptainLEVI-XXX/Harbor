// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHarborBook} from "src/interfaces/IHarborBook.sol";

import {RedemptionAccounting} from "src/libraries/RedemptionAccounting.sol";

import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {RouteConfig, Operation, RedeemIntent} from "src/types/HarborTypes.sol";
import {BookState} from "src/book/base/BookState.sol";
import {IssuerOperations} from "src/libraries/IssuerOperations.sol";

/// @title BookRedemptions
/// @notice Inventory-to-issuer-right transitions and measured cash recovery.
/// @dev Pending rights retain acquisition basis and never become spendable cash.
/// Recovery is permissionless, bounded, and independent of fresh quotes or marks.
abstract contract BookRedemptions is BookState {
  using RedemptionAccounting for RedemptionAccounting.State;

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
    if (intent.route >= INVENTORY_ROUTES) revert InvalidConfiguration();
    RouteConfig storage r = _routes[intent.route];
    bytes32 context =
      _redemptions.consume(intent, amounts, address(VAULT), r.adapter, _state.positions[intent.route].version);
    if (
      intent.shares > _state.positions[intent.route].shares
        || _state.claims.active.length + _claimMarkets.active.length + amounts.length > 64
    ) {
      revert CapacityExceeded();
    }
    _open(context, Operation.REDEMPTION);
    _route = intent.route;
    _cash = intent.shares;
    requests =
      IssuerOperations.request(_state, _redemptions, _protocolIds, r, intent, amounts, address(VAULT), WETH, context);
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
    if (routeId >= INVENTORY_ROUTES) revert InvalidConfiguration();
    if (ids.length == 0 || ids.length > 8 || ids.length != hints.length) revert InvalidConfiguration();
    address adapter = _routes[routeId].adapter;
    _open(keccak256(abi.encode(msg.sender, routeId, ids, hints)), Operation.RECOVERY);
    uint256 total = IssuerOperations.recover(_state, adapter, routeId, ids, hints, address(VAULT), WETH);
    VAULT.settleIssuer(_context, total);
    _release();
  }
}
