// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ClaimImport, ClaimObservation} from "src/types/ClaimTypes.sol";

/// @title IHarborClaimAdapter
/// @notice Approved issuer custody; no generic component interprets issuer calldata.
/// @dev Tokenized credit belongs to the receipt holder, never implicitly to the pool.
/// Factory admission permits new wrapping; retirement must not block existing payouts.
interface IHarborClaimAdapter {
  function FACTORY() external view returns (address);
  function ASSET() external view returns (address);
  /// @notice Preview identity only; this read does not establish custody or import authority.
  function claimId(ClaimImport calldata input) external view returns (bytes32);
  /// @notice Verified lifecycle and settlement-token amounts; invalid marks do not erase ownership.
  function claimState(bytes32 id) external view returns (ClaimObservation memory);
  /// @notice Whether this claim's recovery/payout currently forbids receipt transfers.
  /// @dev Transaction-local signal, not a durable lifecycle stage or a pool-wide lock.
  function claimBusy(bytes32 id) external view returns (bool);
  /// @notice Factory-only custody import, independently verifying owner and canonical receipt.
  /// @return id Canonical claim identity; must match the factory's requested binding.
  /// @return nominal Positive verified entitlement in settlement-token raw units, not guaranteed recovery.
  function importClaim(address owner, ClaimImport calldata input, address receipt)
    external
    returns (bytes32 id, uint256 nominal);
  /// @notice Permissionless collection to this claim's credit, without selecting a beneficiary.
  /// @dev Must respect the pool operation lock; proofs/hints are issuer-specific verified input.
  function recoverTokenized(bytes32 id, bytes calldata data) external returns (uint256 cash);
  /// @notice Canonical receipt only, after the holder's burn; debit credit and pay atomically.
  /// @dev Require aggregate cash backing. A failed payout must restore both credit and receipt.
  function redeemTokenized(bytes32 id, address receiver) external returns (uint256 cash);
}
