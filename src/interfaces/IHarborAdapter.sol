// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Fixed-beneficiary issuer boundary. All amounts are raw token units.
interface IHarborAdapter {
  struct Request {
    uint256 id;
    uint256 shares; // Wrapped inventory actually consumed for this right.
    uint256 entitlement; // Underlying ETH wei, not cash or a guaranteed recovery.
  }

  function BOOK() external view returns (address);
  function VAULT() external view returns (address);
  function BASE() external view returns (address);
  function ASSET() external view returns (address);

  /// @notice Book-only conversion of already transferred inventory into native rights.
  /// @param amounts One to eight wrapped-token quantities, in raw units.
  /// @param previousBalance Adapter's raw BASE balance measured before the Vault handoff.
  function request(uint256[] calldata amounts, uint256 previousBalance) external returns (Request[] memory requests);

  /// @notice Book-only recovery to the fixed Vault, never to the caller or a supplied receiver.
  /// @dev One right per call permits unambiguous receipt attribution. Book batches.
  /// @return cash Measured settlement-token raw units delivered to the Vault.
  /// @return remaining Verified residual nominal entitlement; zero only after native rights close.
  function claim(uint256 id, uint256 hint) external returns (uint256 cash, uint256 remaining);

  /// @notice Adapter-scoped canonical identity for an issuer-native request ID.
  function nativeClaimId(uint256 id) external view returns (bytes32);
}
