// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ClaimDomain, ClaimStage} from "src/types/ClaimTypes.sol";

/// @notice Per-right backing and permanent identities, owned by one custody adapter.
library IssuerClaimLedger {
  struct Claim {
    uint256 issuerId; // Required for issuer calls after tokenization.
    uint256 nominal; // Verified face; never a public price or spendable cash.
    uint256 cash; // This right's unpaid, measured recovery.
    address receipt; // Canonical payout authority; zero for native rights.
    ClaimDomain domain;
    ClaimStage stage; // CLOSED tombstones are never removed or reused.
  }

  struct State {
    mapping(bytes32 => Claim) claims;
    uint256 totalCash; // Solvency gate across all unpaid tokenized claims.
  }
}
