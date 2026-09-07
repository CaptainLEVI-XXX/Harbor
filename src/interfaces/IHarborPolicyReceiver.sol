// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title IHarborPolicyReceiver
/// @notice Independent exact-fill authorization; never a reservation of liquidity.
interface IHarborPolicyReceiver {
  function isApproved(bytes32 fillDigest) external view returns (bool);
}
