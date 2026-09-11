// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title IHarborClaim
/// @notice Common observation and recovery boundary for one indivisible right.
/// @dev Amounts use the recovery token's raw units, never receipt units or NAV.
interface IHarborClaim {
  enum Status {
    UNINITIALIZED,
    PENDING,
    FINALIZED,
    CASH_READY,
    CLOSED
  }

  function FACTORY() external view returns (address);
  function ADAPTER() external view returns (address);
  function ASSET() external view returns (address);
  function CLAIM_ID() external view returns (bytes32);
  function CHAIN_ID() external view returns (uint256);
  function status() external view returns (Status);
  function entitlement() external view returns (uint256);
  function recovered() external view returns (uint256);

  /// @notice Collect attributable recovery into its adapter credit; never choose a beneficiary.
  function recover(bytes calldata data) external returns (uint256 cash);
  /// @notice Burn the caller's entire receipt and pay its recorded recovery.
  function redeem(address recipient) external returns (uint256 cash);
}

/// @notice Optional export boundary for an adapter's already accepted native right.
interface IHarborClaimExporter {
  function ISSUER() external view returns (address);
  function exportClaim(uint256 id, address factory) external returns (address receipt);
}
