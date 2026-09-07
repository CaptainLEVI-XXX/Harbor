// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {Amounts} from "src/libraries/Amounts.sol";
import {Trade, FillTerms, FillAmounts, Side} from "src/types/HarborTypes.sol";

/// @title QuoteValidation
/// @notice Deterministic amount and public-price guards on authenticated inputs.
library QuoteValidation {
  error InconsistentAmounts();
  error PublicPriceViolation();
  error InvalidPricePolicy();

  function amounts(Trade memory trade, FillTerms memory terms) internal pure returns (FillAmounts memory a) {
    a = Amounts.normalize(trade, terms.traderIn, terms.traderOut, terms.feeBps);
    if (a.routerIn != terms.routerIn || a.routerOut != terms.routerOut || a.fee != terms.fee) {
      revert InconsistentAmounts();
    }
  }

  /// @notice Bound gross purchase debit or net resale receipt in WETH wei.
  /// @param entitlement Verified entitlement for the exact base quantity, WETH wei.
  /// @param multiplier Bid/ask in 1e18 scale.
  /// @param buffer Nonnegative WETH adjustment, applied against the maker's spend.
  function price(Side side, uint256 cash, uint256 entitlement, uint256 multiplier, uint256 buffer) internal pure {
    if (multiplier == 0 || (side == Side.BUY_BASE && multiplier > 1e18)) revert InvalidPricePolicy();
    if (side == Side.BUY_BASE) {
      uint256 ceiling = Math.fullMulDiv(entitlement, multiplier, 1e18);
      if (ceiling < buffer || cash > ceiling - buffer) revert PublicPriceViolation();
    } else if (cash < Math.fullMulDivUp(entitlement, multiplier, 1e18) + buffer) {
      revert PublicPriceViolation();
    }
  }
}
