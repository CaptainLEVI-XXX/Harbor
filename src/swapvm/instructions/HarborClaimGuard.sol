// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";
import {IHarborClaimFactory} from "src/interfaces/IHarborClaimFactory.sol";

/// @title HarborClaimGuard
/// @notice Verify one canonical pending right after exact amounts are established.
/// @dev Shared Book validation, not a custom opcode. Called during the official
/// Extruction pricing path and again at the final custody/settlement boundary.
library HarborClaimGuard {
  error InvalidClaim();

  /// @notice Validate custody and exactly one receipt in either token direction.
  /// @dev Buy means the maker receives the receipt. Retirement blocks purchases;
  /// a newly versioned sale can still release existing exposure.
  function check(
    address receipt,
    address factory,
    uint256 version,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut
  ) internal view {
    IHarborClaim c = IHarborClaim(receipt);
    IHarborClaimFactory f = IHarborClaimFactory(factory);
    bool buy = tokenIn == receipt;
    if (
      c.FACTORY() != factory || !f.isReceipt(receipt) || f.receiptOf(c.ADAPTER(), c.CLAIM_ID()) != receipt
        || c.ASSET() != f.ASSET() || c.CHAIN_ID() != block.chainid || f.version(c.ADAPTER()) != version
        || c.status() != IHarborClaim.Status.PENDING
        || (buy
            ? (tokenOut != c.ASSET() || amountIn != 1 || !f.active(c.ADAPTER()))
            : (tokenOut != receipt || tokenIn != c.ASSET() || amountOut != 1))
    ) revert InvalidClaim();
  }
}
