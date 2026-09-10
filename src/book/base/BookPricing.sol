// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StandingPricing} from "src/libraries/StandingPricing.sol";
import {BookState} from "src/book/base/BookState.sol";
import {IHarborBook} from "src/interfaces/IHarborBook.sol";
import {BookPortfolio} from "src/libraries/BookPortfolio.sol";
import {PricingMath} from "src/libraries/PricingMath.sol";
import {Trade, FillAmounts, Operation} from "src/types/HarborTypes.sol";
import {PricingPolicy, PricingParameters, PricingCurve} from "src/types/PricingTypes.sol";

/// @title BookPricing
/// @notice Bounded publication and live-state pricing under the Book's single authority.
/// @dev Public reads and SwapVM execution share _quote. No quote signatures,
/// historical price ledger, private NAV or discretionary per-trade permits.
abstract contract BookPricing is BookState {
  event PricingPolicyConfigured(uint256 indexed route, PricingPolicy policy);
  event PricingParametersPublished(
    uint256 indexed route,
    uint256 indexed version,
    uint256 indexed configVersion,
    uint256 discount,
    uint256 observedAt,
    uint256 validUntil
  );

  /// @notice Configure one admitted route exactly once, independently of its updater.
  function configurePricing(uint256 route, PricingPolicy calldata policy) external {
    if (msg.sender != GOVERNOR) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    if (route >= INVENTORY_ROUTES + _claimMarkets.count || _pricingPolicies[route].minDiscount != 0) {
      revert InvalidConfiguration();
    }
    PricingMath.validatePolicy(policy, pricingCurve());
    _pricingPolicies[route] = policy;
    emit PricingPolicyConfigured(route, policy);
  }

  /// @notice Publish one reusable discount through an ordinary authenticated transaction.
  /// @dev Version must advance by one, including after expiry/revocation. Config
  /// is supplied to reject stale queued updates. Publication never touches NAV.
  function publishPricing(uint256 route, PricingParameters calldata p) external {
    if (msg.sender != parameterUpdater) revert Unauthorized();
    if (_operation != Operation.NONE) revert Busy();
    PricingPolicy storage policy = _pricingPolicies[route];
    if (
      policy.minDiscount == 0 || p.discount < policy.minDiscount || p.discount > policy.maxDiscount
        || p.configVersion != configVersion || p.version != _prices[route].version + 1 || p.observedAt == 0
        || p.observedAt > block.timestamp || p.validUntil < block.timestamp || p.validUntil < p.observedAt
        || p.validUntil - p.observedAt > MAX_PARAMETER_AGE || p.observedAt < _prices[route].observedAt
    ) revert InvalidQuote();
    _prices[route] = p;
    emit PricingParametersPublished(route, p.version, p.configVersion, p.discount, p.observedAt, p.validUntil);
  }

  function pricingParameters(uint256 route) external view returns (PricingParameters memory) {
    return _prices[route];
  }

  function pricingPolicy(uint256 route) external view returns (PricingPolicy memory) {
    return _pricingPolicies[route];
  }

  function pricingCurve() public view returns (PricingCurve memory) {
    return PricingCurve(FACE_CAP, TARGET_UTILIZATION, CAPACITY_PENALTY);
  }

  /// @notice Nominal outstanding rights; pending claims are never spendable cash.
  function faceExposure() public view returns (uint256) {
    return BookPortfolio.face(_state, _claimMarkets, _routes, VALUATION, INVENTORY_ROUTES, address(VAULT));
  }

  /// @inheritdoc IHarborBook
  function quote(Trade calldata trade) external view returns (FillAmounts memory) {
    if (_operation != Operation.NONE) revert Busy();
    return _quote(trade);
  }

  /// @dev Caller separately authenticates idle/static or locked/mutable context.
  function _quote(Trade memory t) internal view returns (FillAmounts memory a) {
    PricingParameters memory p = _prices[t.route];
    if (
      stopped || parameterUpdater == address(0) || t.route >= INVENTORY_ROUTES + _claimMarkets.count || p.version == 0
        || t.pricingVersion != p.version || t.configVersion != configVersion || p.configVersion != configVersion
        || t.strategyVersion != strategyVersion[t.route] || strategyHash[t.route] == 0 || block.timestamp > t.deadline
        || block.timestamp > p.validUntil
    ) revert InvalidQuote();
    return StandingPricing.quote(
      _state,
      _claimMarkets,
      _routes,
      t,
      _pricingPolicies[t.route],
      p.discount,
      strategyFactoryVersion[t.route],
      strategyHash[t.route],
      StandingPricing.Config(
        address(VAULT),
        address(EXECUTOR),
        WETH,
        AQUA,
        ROUTER,
        FEE_RECIPIENT,
        VALUATION,
        INVENTORY_ROUTES,
        FEE_BPS,
        CASH_BUFFER,
        MAX_EXPOSURE,
        MAX_MARK_AGE,
        pricingCurve()
      )
    );
  }
}
