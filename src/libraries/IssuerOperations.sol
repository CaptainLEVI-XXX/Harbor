// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SafeTransferLib as SafeTransfer} from "solady/utils/SafeTransferLib.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";
import {IHarborTreasury} from "src/interfaces/IHarborTreasury.sol";
import {BookAccounting as Accounting} from "src/libraries/BookAccounting.sol";
import {ClaimAccounting} from "src/libraries/ClaimAccounting.sol";
import {RedemptionAccounting} from "src/libraries/RedemptionAccounting.sol";
import {RouteConfig, RedeemIntent} from "src/types/HarborTypes.sol";

/// @title IssuerOperations
/// @notice Linked native-issuer transitions on explicit Book storage.
/// @dev The Book authenticates caller/context and locks the vault before entry.
library IssuerOperations {
  error InvalidConfiguration();
  error SettlementMismatch();
  event RedemptionRequested(
    bytes32 indexed intent,
    uint256 indexed route,
    uint256 indexed id,
    uint256 shares,
    uint256 basis,
    uint256 entitlement
  );
  event RedemptionRecovered(uint256 indexed route, uint256 indexed id, uint256 cash, uint256 remaining);

  /// @notice Move verified inventory into one to eight issuer rights, retaining WETH-denominated cost.
  /// @dev Caller authenticates the intent and shared capacity before entry. Amounts are wrapped-token units.
  function request(
    Accounting.State storage state,
    RedemptionAccounting.State storage redemptions,
    mapping(bytes32 => uint256) storage protocolIds,
    RouteConfig memory r,
    RedeemIntent memory intent,
    uint256[] memory amounts,
    address vault,
    address weth,
    bytes32 context
  ) public returns (IHarborAdapter.Request[] memory requests) {
    IHarborAdapter adapter = IHarborAdapter(r.adapter);
    if (
      adapter.BOOK() != address(this) || adapter.VAULT() != vault || adapter.BASE() != r.base || adapter.WETH() != weth
    ) revert InvalidConfiguration();
    uint256 previousBalance = SafeTransfer.balanceOf(r.base, r.adapter);
    IHarborTreasury(vault).transferForRedemption(context);
    requests = adapter.request(amounts, previousBalance);
    if (requests.length != amounts.length) revert SettlementMismatch();
    uint256 underlying;
    for (uint256 i; i < requests.length; ++i) {
      IHarborAdapter.Request memory item = requests[i];
      if (item.shares != amounts[i] || item.id == 0) revert SettlementMismatch();
      bytes32 key = ClaimAccounting.key(r.adapter, item.id);
      uint256 basis = Accounting.request(state, intent.route, item.shares, key, item.entitlement);
      protocolIds[key] = item.id;
      underlying += item.entitlement;
      emit RedemptionRequested(context, intent.route, item.id, item.shares, basis, item.entitlement);
    }
    RedemptionAccounting.record(redemptions, intent.route, underlying, intent.minUnderlying, r.maxDailyRedemption);
  }

  /// @notice Recover a strictly ordered batch into the fixed vault, recording measured WETH wei.
  /// @dev Caller enforces nonempty, equal-length arrays of at most eight and owns the operation lock.
  function recover(
    Accounting.State storage state,
    address adapter,
    uint256 route,
    uint256[] memory ids,
    uint256[] memory hints,
    address vault,
    address weth
  ) public returns (uint256 total) {
    for (uint256 i; i < ids.length; ++i) {
      if (i != 0 && ids[i] <= ids[i - 1]) revert InvalidConfiguration();
      bytes32 key = ClaimAccounting.key(adapter, ids[i]);
      ClaimAccounting.Claim storage c = state.claims.claims[key];
      if (!c.exists || c.closed || c.route != route) revert InvalidConfiguration();
      uint256 beforeBalance = SafeTransfer.balanceOf(weth, vault);
      (uint256 cash, uint256 remaining) = IHarborAdapter(adapter).claim(ids[i], hints[i]);
      if (SafeTransfer.balanceOf(weth, vault) != beforeBalance + cash) revert SettlementMismatch();
      Accounting.recover(state, key, cash, remaining);
      total += cash;
      emit RedemptionRecovered(route, ids[i], cash, remaining);
    }
  }
}
