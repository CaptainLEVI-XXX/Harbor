// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";

/// @title Fees
/// @notice WETH-only fee arithmetic with upward fee rounding.
library Fees {
  uint256 internal constant DENOMINATOR = 10_000;
  /// @notice A rate of 100% or more has no invertible net amount.
  error InvalidFee(uint256 bps);

  /// @notice Net WETH wei after deducting ceil(gross * bps / 10_000).
  function net(uint256 gross, uint256 bps) internal pure returns (uint256) {
    if (bps >= DENOMINATOR) revert InvalidFee(bps);
    return Math.fullMulDiv(gross, DENOMINATOR - bps, DENOMINATOR);
  }

  /// @notice Smallest gross WETH wei producing exactly the requested net wei.
  /// @dev Reverts if that gross amount is not representable as uint256.
  function grossForNet(uint256 amount, uint256 bps) internal pure returns (uint256) {
    if (bps >= DENOMINATOR) revert InvalidFee(bps);
    return Math.fullMulDivUp(amount, DENOMINATOR, DENOMINATOR - bps);
  }
}
