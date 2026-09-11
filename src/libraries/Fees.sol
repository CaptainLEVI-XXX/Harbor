// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title Fees
/// @notice ASSET-only arithmetic matching the pinned SwapVM FeeProtocol.
library Fees {
  uint256 internal constant DENOMINATOR = 10_000;
  /// @notice A rate of 100% or more has no invertible net amount.
  error InvalidFee(uint256 bps);

  /// @notice Gross less floor(gross * bps / 10_000).
  function net(uint256 gross, uint256 bps) internal pure returns (uint256) {
    if (bps >= DENOMINATOR) revert InvalidFee(bps);
    return gross - Math.fullMulDiv(gross, bps, DENOMINATOR);
  }

  /// @notice Upstream inverse: net + floor(net * bps / (10_000 - bps)).
  /// @dev At fee plateaus this need not be the smallest gross producing that net.
  /// @dev Reverts if that gross amount is not representable as uint256.
  function grossForNet(uint256 amount, uint256 bps) internal pure returns (uint256) {
    if (bps >= DENOMINATOR) revert InvalidFee(bps);
    return amount + Math.fullMulDiv(amount, bps, DENOMINATOR - bps);
  }
}
