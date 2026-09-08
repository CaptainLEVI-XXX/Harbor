// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title IHarborTreasury
/// @notice Restricted issuer handoff, callable only by the Book under its active context.
interface IHarborTreasury {
  /// @param context Exact request identity; asset, amount and adapter are resolved from Book.
  function transferForRedemption(bytes32 context) external;
}
