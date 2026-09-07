// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title IHarborBook
/// @notice Vault-facing authority and public-valuation boundary.
interface IHarborBook {
  /// @notice Acquire Book then Vault context for a vault-originated operation.
  function beginVaultOperation(bytes32 context) external;
  /// @notice Release Vault then Book context after the vault commits accounting.
  function finishVaultOperation(bytes32 context) external;
  /// @notice Public marks in WETH wei; this must not be a private quote report.
  /// @return inventory Managed inventory value.
  /// @return claims Remaining issuer rights value.
  /// @return observedAt Oldest observation timestamp in Unix seconds.
  /// @return policyVersion Public valuation policy version.
  /// @return valid Whether the mark and real-capital launch gate are valid.
  function valuation()
    external
    view
    returns (uint256 inventory, uint256 claims, uint256 observedAt, uint256 policyVersion, bool valid);
}
