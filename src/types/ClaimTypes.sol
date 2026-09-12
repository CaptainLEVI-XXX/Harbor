// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";

enum CollateralKind {
  ERC721,
  ERC20_AMOUNT
}
enum ClaimDomain {
  NONE,
  NATIVE_VAULT,
  TOKENIZED,
  RAW_VAULT
}
enum ClaimStage {
  NONE,
  PENDING,
  CASH_READY,
  CLOSED
}

/// @notice Describes collateral; the approved adapter independently proves ownership.
struct ClaimImport {
  CollateralKind kind;
  address asset;
  uint256 tokenId;
  uint256 amount;
  bytes data;
}

/// @notice Settlement-asset raw units. Invalid marks do not invalidate ownership.
struct ClaimObservation {
  ClaimDomain domain;
  IHarborClaim.Status status;
  uint256 entitlement;
  uint256 mark;
  uint256 cash;
  uint256 observedAt;
  bool valid;
}

struct InventoryObservation {
  uint256 entitlement;
  uint256 mark;
  uint256 observedAt;
  bytes32 observationHash;
  bool valid;
}
