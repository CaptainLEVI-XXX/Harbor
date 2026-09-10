// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {BookState} from "src/book/base/BookState.sol";
import {ClaimMarkets} from "src/libraries/ClaimMarkets.sol";
import {Operation} from "src/types/HarborTypes.sol";

/// @title BookClaims
/// @notice Individually approved claim markets, custody exports and vault receipt recovery.
/// @dev All entrypoints share the existing Book/Vault transaction lock. Prices and
/// token settlement remain in the standing-pricing executor and router.
abstract contract BookClaims is BookState {
  /// @notice Effective factory admission and exact quote invalidation epoch.
  event ClaimIntegrationStatusChanged(address indexed factory, bool enabled, bool retired, uint256 configVersion);

  /// @notice Schedule a factory against a native issuer and immutable claim price bounds.
  /// @param source Original inventory route; all descendant markets share its risk limits.
  /// @param bid Maximum purchase multiplier on public mark, scaled by 1e18.
  /// @param ask Minimum sale multiplier on public mark, scaled by 1e18, between bid and one.
  function scheduleClaimFactory(address factory, uint256 source, uint256 bid, uint256 ask) external {
    _claimAdmin();
    ClaimMarkets.schedule(_claimMarkets, _routes, factory, source, bid, ask, GOVERNANCE_DELAY, address(VAULT), WETH);
  }

  /// @notice Enable a reviewed configuration after its governance delay.
  function activateClaimFactory(address factory) external {
    _claimAdmin();
    ClaimMarkets.activate(_claimMarkets, factory);
    emit ClaimIntegrationStatusChanged(factory, true, false, ++configVersion);
  }

  /// @notice Irreversibly disable new exposure; existing recovery and sales remain available.
  function retireClaimFactory(address factory) external {
    if (msg.sender != GOVERNOR && msg.sender != GUARDIAN) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    ClaimMarkets.retire(_claimMarkets, factory);
    emit ClaimIntegrationStatusChanged(factory, false, true, ++configVersion);
  }

  /// @notice Admit one canonical pending receipt as a stable route, without acquiring it.
  /// @return route New route ID; governor subsequently publishes it through the vault.
  function registerClaimMarket(address factory, address receipt) external returns (uint256 route) {
    _claimAdmin();
    if (stopped) revert Unauthorized();
    route = ClaimMarkets.register(_claimMarkets, _routes, factory, receipt, WETH);
  }

  /// @notice Move a managed native right to one vault-owned receipt without realizing PnL.
  /// @dev External NFT custody and Book basis movement roll back together on any failure.
  function exportClaim(uint256 source, uint256 id, address factory) external returns (uint256 route) {
    _claimAdmin();
    if (stopped) revert Unauthorized();
    _open(keccak256(abi.encode(msg.sender, source, id, factory)), Operation.RECOVERY);
    route = ClaimMarkets.exportRight(_claimMarkets, _state, _routes, source, id, factory, address(VAULT), WETH);
    VAULT.settleIssuer(_context, 0);
    _release();
  }

  /// @notice Recover and redeem a held receipt even if quotes, marks or admission are unavailable.
  /// @param route Stable receipt route; the vault must hold its managed one-unit position.
  /// @param hint Protocol-specific recovery proof; ignored if cash was already collected.
  function recoverClaim(uint256 route, uint256 hint) external returns (uint256 cash) {
    if (_claimMarkets.markets[route].factory == address(0) || _state.positions[route].shares != 1) {
      revert InvalidConfiguration();
    }
    _open(keccak256(abi.encode(msg.sender, route, hint)), Operation.RECOVERY);
    cash = VAULT.recoverReceipt(_context, _claimMarkets.markets[route].receipt, hint);
    ClaimMarkets.dispose(_claimMarkets, _state, route, cash, true);
    VAULT.settleIssuer(_context, cash);
    _release();
  }

  /// @notice Read immutable market identity; acquisition history is reconstructed from receipt events.
  function claimMarket(uint256 route) external view returns (ClaimMarkets.Market memory) {
    return _claimMarkets.markets[route];
  }

  function claimIntegration(address factory) external view returns (ClaimMarkets.Integration memory) {
    return _claimMarkets.integrations[factory];
  }

  /// @notice Receipt-only totals; issuer-wide limits also include the native route position.
  function claimTotals(uint256 source) external view returns (ClaimMarkets.Totals memory) {
    return _claimMarkets.totals[source];
  }

  /// @notice At most 64 combined native/receipt positions can be held.
  function activeReceiptCount() external view returns (uint256) {
    return _claimMarkets.active.length;
  }

  /// @notice Discover up to 32 held receipt routes; point queries resolve canonical identity and cost.
  /// @dev Start cursor at zero and pin all pages to one block. Swap-pop removal changes offsets.
  /// @param cursor Live-set offset, not a stable route ID.
  /// @param limit Page size, 1..32; an empty page at next indicates the end.
  /// @return routes Stable receipt IDs for currently held one-unit positions.
  /// @return next Live-set cursor immediately after this page.
  function activeReceiptRoutes(uint256 cursor, uint256 limit)
    external
    view
    returns (uint256[] memory routes, uint256 next)
  {
    return ClaimMarkets.activeRoutes(_claimMarkets, cursor, limit);
  }

  function _claimAdmin() private view {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
  }
}
