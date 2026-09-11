// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StandingPricing} from "src/libraries/StandingPricing.sol";
import {BookState} from "src/book/base/BookState.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {PricingState} from "src/libraries/PricingState.sol";
import {Trade, FillAmounts, Operation} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingParameters, PricingCurve} from "src/types/PricingTypes.sol";

/// @title BookPricing
/// @notice Bounded publication and live-state pricing under the Book's single authority.
/// @dev Public reads and SwapVM execution share the pricing kernel. No quote signatures,
/// historical price ledger, private NAV or discretionary per-trade permits.
abstract contract BookPricing is BookState {
  /// @notice Configure one admitted route exactly once, independently of its updater.
  function configurePricing(uint256 route, PricingPolicy calldata policy) external {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    PricingState.configure(_pricing, route, INVENTORY_ROUTES + _claimMarkets.count, policy, pricingCurve(), ASSET_UNIT);
  }

  /// @notice Publish one reusable discount through an ordinary authenticated transaction.
  /// @dev Version must advance by one, including after expiry/revocation. Config
  /// is supplied to reject stale queued updates. Publication never touches NAV.
  function publishPricing(uint256 route, PricingParameters calldata p) external {
    if (msg.sender != parameterUpdater) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    PricingState.publish(_pricing, route, p, configVersion, MAX_PARAMETER_AGE);
  }

  function pricingParameters(uint256 route) external view returns (PricingParameters memory) {
    return _pricing.parameters[route];
  }

  function pricingPolicy(uint256 route) external view returns (PricingPolicy memory) {
    return _pricing.policies[route];
  }

  function pricingCurve() public view returns (PricingCurve memory) {
    return PricingCurve(FACE_CAP, TARGET_UTILIZATION, CAPACITY_PENALTY);
  }

  /// @notice Nominal outstanding rights; pending claims are never spendable cash.
  function faceExposure() public view returns (uint256) {
    return BookPortfolio.face(_state, _claimMarkets, _routes, INVENTORY_ROUTES, address(VAULT));
  }

  /// @inheritdoc IHarborBook
  function quote(Trade calldata trade) external view returns (FillAmounts memory) {
    if (_operation != Operation.NONE) revert Busy();
    return _quote(trade);
  }

  /// @dev Caller separately authenticates idle/static or locked/mutable context.
  function _quote(Trade memory t) internal view returns (FillAmounts memory a) {
    (a,,) = _quoteWithValue(t, false, 0);
  }

  /// @dev Preparation reuses the independently obtained value; never mark NAV from pricing parameters.
  function _quoteWithValue(Trade memory t, bool vmPricing, uint256 specified)
    internal
    view
    returns (FillAmounts memory a, BookPortfolio.Value memory value, bytes32 evidence)
  {
    return this.priceTrade(t, vmPricing, specified);
  }

  /// @notice Shared read-only pricing boundary for this Book's preview and VM paths.
  /// @dev Self-call only: callers cannot bypass the entrypoint's idle/context
  /// checks. One ABI boundary keeps large configuration/ledger encoding out of
  /// both inlined entrypoints; fixed library links retain the Book's storage.
  function priceTrade(Trade calldata t, bool vmPricing, uint256 specified)
    external
    view
    returns (FillAmounts memory a, BookPortfolio.Value memory value, bytes32 evidence)
  {
    if (msg.sender != address(this)) revert Unauthorized();
    StandingPricing.Config memory c = StandingPricing.Config(
      address(VAULT),
      address(EXECUTOR),
      ASSET,
      AQUA,
      ROUTER,
      FEE_RECIPIENT,
      INVENTORY_ROUTES,
      FEE_BPS,
      CASH_BUFFER,
      MAX_EXPOSURE,
      MAX_MARK_AGE,
      pricingCurve(),
      vmPricing,
      specified,
      stopped,
      parameterUpdater,
      configVersion,
      ASSET_UNIT
    );
    return StandingPricing.quote(
      _state, _claimMarkets, _routes, _pricing, strategyVersion, strategyHash, strategyFactoryVersion, t, c
    );
  }
}
