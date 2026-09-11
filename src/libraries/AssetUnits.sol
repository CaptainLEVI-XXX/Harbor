// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title AssetUnits
/// @notice Bounded whole-token units for approved, fixed-decimal ERC-20s.
/// @dev Metadata is an integration assumption, not an exchange-rate oracle.
library AssetUnits {
  error InvalidDecimals();

  function unit(address token) internal view returns (uint256) {
    return 10 ** uint256(decimals(token));
  }

  function decimals(address token) internal view returns (uint8 value) {
    value = IERC20Metadata(token).decimals();
    if (value < 6 || value > 18) revert InvalidDecimals();
  }
}
