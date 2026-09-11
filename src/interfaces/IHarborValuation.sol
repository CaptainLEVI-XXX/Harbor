// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;
import {InventoryObservation, ClaimObservation} from "src/types/ClaimTypes.sol";

/// @title IHarborValuation
/// @notice Public observation provider, fixed at deployment and independent of quotes.
/// @dev Implementations verify provenance/conversion and separately authorized estimates.
interface IHarborValuation {
  /// @notice One exact inventory observation and an ordered batch of known, unique claims.
  /// @dev At most 64 IDs. Cash is attributable credit, not automatically Vault liquidity.
  function observePortfolio(address base, uint256 quantity, bytes32[] calldata ids)
    external
    view
    returns (InventoryObservation memory inventoryValue, ClaimObservation[] memory claims);
  /// @notice Exact protocol-native nominal conversion, independent of marking estimates.
  /// @dev Raw base units convert to raw settlement-asset units. Neither value is a rounded one-token price.
  function conversion(address base) external view returns (uint256 numerator, uint256 denominator);
  /// @notice Values the exact non-rebasing token quantity in settlement-asset raw units.
  /// @return entitlement Verified issuer conversion, not a cash guarantee.
  /// @return mark Public-policy LP inventory mark for these units.
  /// @return observedAt Oldest required observation timestamp.
  /// @return policyVersion Immutable/public marking policy version.
  /// @return observationHash Commitment to the public observations used.
  /// @return valid Issuer evidence and estimate freshness are valid; not a launch or audit approval.
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
