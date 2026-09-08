// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title IHarborClaim
/// @notice Common observation and recovery boundary for one indivisible right.
/// @dev Amounts use the recovery token's raw units, never receipt units or NAV.
interface IHarborClaim {
  enum Status { UNINITIALIZED, PENDING, FINALIZED, CASH_READY, CLOSED }

  function FACTORY() external view returns (address);
  function ISSUER() external view returns (address);
  function WETH() external view returns (address);
  function REQUEST_ID() external view returns (uint256);
  function status() external view returns (Status);
  function entitlement() external view returns (uint256);
  function recovered() external view returns (uint256);

  /// @notice Collect attributable recovery into the receipt; never choose a beneficiary.
  function recover(uint256 hint) external returns (uint256 cash);
  /// @notice Burn the caller's entire receipt and pay its recorded recovery.
  function redeem(address recipient) external returns (uint256 cash);
}

/// @title IHarborClaimFactory
/// @notice Admission is external to this interface: compatible code is not approval.
interface IHarborClaimFactory {
  function ISSUER() external view returns (address);
  function WETH() external view returns (address);
  function version() external view returns (uint256);
  function active() external view returns (bool);
  function isReceipt(address receipt) external view returns (bool);
  function receiptOf(uint256 id) external view returns (address);
  /// @notice Import an existing request owned by the caller; quantity is protocol-native.
  function wrap(uint256 id) external returns (address receipt);
  /// @notice Optional new-request capability. Unsupported implementations must revert.
  function originate(uint256 amount) external returns (address receipt);
}
