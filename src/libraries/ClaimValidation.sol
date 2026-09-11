// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IHarborClaimFactory} from "src/interfaces/IHarborClaimFactory.sol";

/// @title ClaimValidation
/// @notice Live trading conditions for an already admitted, canonical receipt.
/// @dev ClaimMarkets.register proves immutable receipt/factory/adapter/asset
/// identity. Token direction is checked by StandingPricing and bound to hooks.
/// Reuse one live status per boundary; never reuse it across transfer callbacks.
library ClaimValidation {
  error InvalidClaim();

  /// @dev Retirement blocks acquisitions, not newly authorized inventory sales.
  function check(
    address factory,
    address adapter,
    uint256 version,
    bool buy,
    uint256 quantity,
    IHarborClaim.Status status
  ) internal view {
    IHarborClaimFactory f = IHarborClaimFactory(factory);
    if (
      quantity != 1 || status != IHarborClaim.Status.PENDING || f.version(adapter) != version
        || (buy && !f.active(adapter))
    ) revert InvalidClaim();
  }
}
