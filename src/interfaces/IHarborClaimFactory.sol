// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ClaimImport} from "src/types/ClaimTypes.sol";

/// @title IHarborClaimFactory
/// @notice Permanent canonical receipts and separately scoped adapter admission.
/// @dev Registry membership establishes identity, not current ownership, pending status or pool approval.
interface IHarborClaimFactory {
  function ASSET() external view returns (address);
  /// @notice Adapter admission epoch bound into each published receipt trading program.
  function version(address adapter) external view returns (uint256);
  /// @notice Whether new receipts may be created; existing payout rights are independent.
  function active(address adapter) external view returns (bool);
  /// @notice Permanent recognition, including receipts whose sole unit has been redeemed.
  function isReceipt(address receipt) external view returns (bool);
  /// @notice Unique adapter/claim binding; zero before creation, never cleared after payout.
  function receiptOf(address adapter, bytes32 id) external view returns (address);
  /// @notice Atomically import caller-owned collateral through an approved adapter and mint one raw unit.
  function wrap(address adapter, ClaimImport calldata input, address receiver) external returns (address);
  /// @notice Bound adapter only; creates ownership of an already verified native right.
  function exportClaim(bytes32 id, address receiver) external returns (address);
}
