// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Governance-owned route policy. Factors use 1e18; costs are WETH wei.
/// @dev Immutable after route configuration. Updaters can publish discounts only.
struct PricingPolicy {
  uint256 minDiscount;
  uint256 maxDiscount;
  uint256 buyMargin;
  uint256 sellMargin;
  uint256 buyCost;
  uint256 sellCost;
}

/// @notice Reusable route observation, never a trader-specific authorization.
/// @dev Times are Unix seconds; configVersion binds admission and authority changes.
struct PricingParameters {
  uint256 discount;
  uint256 observedAt;
  uint256 validUntil;
  uint256 version;
  uint256 configVersion;
}

/// @notice Fixed vault-wide FACE curve; capacity uses WETH wei, factors use 1e18.
struct PricingCurve {
  uint256 capacity;
  uint256 target;
  uint256 kappa;
}

/// @notice Verified same-state input to pure pricing. No external calls during inversion.
struct PricingMarket {
  PricingPolicy policy;
  uint256 discount;
  uint256 exposure;
  uint256 numerator; // Exact nominal conversion: floor(raw quantity * numerator / denominator).
  uint256 denominator;
  uint256 maxQuantity; // Managed inventory on sells; bounded FACE headroom on buys.
  bool receipt; // One indivisible raw unit; numerator is its nominal entitlement.
}
