// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title IHarborValuation
/// @notice Public observation provider, fixed at deployment and independent of quotes.
/// @dev Implementations must prove provenance, issuer conversion and executable marks.
interface IHarborValuation {
  /// @notice Exact protocol-native nominal conversion, independent of marking estimates.
  /// @dev Approved inventory uses 18 decimals. Neither value is a rounded one-token price.
  function conversion(address base) external view returns (uint256 numerator, uint256 denominator);
  /// @notice Public value of a tracked residual right; never a spendable balance.
  function claim(address adapter, uint256 id, uint256 remaining)
    external
    view
    returns (uint256 mark, uint256 observedAt, uint256 policyVersion, bool valid);
  /// @notice Values the exact non-rebasing token quantity in WETH wei.
  /// @return entitlement Verified issuer conversion, not a cash guarantee.
  /// @return mark Public-policy LP inventory mark for these units.
  /// @return observedAt Oldest required observation timestamp.
  /// @return policyVersion Immutable/public marking policy version.
  /// @return observationHash Commitment to the public observations used.
  /// @return valid Includes data validity and the real-capital launch gate.
  function inventory(address base, uint256 shares)
    external
    view
    returns (
      uint256 entitlement,
      uint256 mark,
      uint256 observedAt,
      uint256 policyVersion,
      bytes32 observationHash,
      bool valid
    );
}
