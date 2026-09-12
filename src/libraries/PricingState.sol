// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PricingPolicy, PricingParameters, PricingCurve} from "src/types/PricingTypes.sol";
import {PricingMath} from "src/libraries/PricingMath.sol";

/// @title PricingState
/// @notice Book-owned standing publications and immutable per-route publisher bounds.
/// @dev Linked operations use explicit Book storage. The Book authenticates roles and its idle lock.
library PricingState {
  /// @dev Admission bounds every field by 1e18. Four factors occupy one slot,
  /// both raw-asset costs another; the external policy ABI remains uint256.
  struct StoredPolicy {
    uint64 minDiscount;
    uint64 maxDiscount;
    uint64 buyMargin;
    uint64 sellMargin;
    uint64 buyCost;
    uint64 sellCost;
  }

  struct State {
    mapping(uint256 => PricingParameters) parameters;
    mapping(uint256 => StoredPolicy) policies;
  }
  error InvalidConfiguration();
  error InvalidQuote();
  event PricingPolicyConfigured(uint256 indexed route, PricingPolicy policy);
  event NftPolicyConfigured(uint256 indexed route, PricingPolicy policy);
  event NftPricingPublished(uint256 indexed route, PricingParameters parameters);
  event PricingParametersPublished(
    uint256 indexed route,
    uint256 indexed version,
    uint256 indexed configVersion,
    uint256 discount,
    uint256 observedAt,
    uint256 validUntil
  );

  function configure(
    State storage self,
    uint256 route,
    uint256 routeCount,
    PricingPolicy memory policy,
    PricingCurve memory curve,
    uint256 assetUnit
  ) public {
    configure(self, route, routeCount, policy, curve, assetUnit, false);
  }

  /// @dev Distinct event domains keep token and NFT policies independently reconstructible.
  function configure(
    State storage self,
    uint256 route,
    uint256 routeCount,
    PricingPolicy memory policy,
    PricingCurve memory curve,
    uint256 assetUnit,
    bool nft
  ) public {
    if (
      route >= routeCount || self.policies[route].minDiscount != 0 || policy.buyCost > assetUnit
        || policy.sellCost > assetUnit
    ) {
      revert InvalidConfiguration();
    }
    PricingMath.validatePolicy(policy, curve);
    self.policies[route] = StoredPolicy(
      uint64(policy.minDiscount),
      uint64(policy.maxDiscount),
      uint64(policy.buyMargin),
      uint64(policy.sellMargin),
      uint64(policy.buyCost),
      uint64(policy.sellCost)
    );
    if (nft) emit NftPolicyConfigured(route, policy);
    else emit PricingPolicyConfigured(route, policy);
  }

  /// @notice Current observation only; history is emitted, never accumulated in storage.
  function publish(State storage self, uint256 route, PricingParameters memory p, uint256 configVersion, uint256 maxAge)
    public
  {
    publish(self, route, p, configVersion, maxAge, false);
  }

  function publish(
    State storage self,
    uint256 route,
    PricingParameters memory p,
    uint256 configVersion,
    uint256 maxAge,
    bool nft
  ) public {
    StoredPolicy storage policy = self.policies[route];
    PricingParameters storage previous = self.parameters[route];
    if (
      policy.minDiscount == 0 || p.discount < policy.minDiscount || p.discount > policy.maxDiscount
        || p.configVersion != configVersion || p.version != previous.version + 1 || p.observedAt == 0
        || p.observedAt > block.timestamp || p.validUntil < block.timestamp || p.validUntil - p.observedAt > maxAge
        || p.observedAt < previous.observedAt
    ) revert InvalidQuote();
    self.parameters[route] = p;
    if (nft) emit NftPricingPublished(route, p);
    else emit PricingParametersPublished(route, p.version, p.configVersion, p.discount, p.observedAt, p.validUntil);
  }

  /// @notice Expand the admitted packed policy without changing its public units.
  function loadPolicy(State storage self, uint256 route) internal view returns (PricingPolicy memory p) {
    StoredPolicy storage s = self.policies[route];
    p = PricingPolicy(s.minDiscount, s.maxDiscount, s.buyMargin, s.sellMargin, s.buyCost, s.sellCost);
  }
}
