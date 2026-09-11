// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {AmountMode, Trade, FillAmounts} from "src/types/HarborTypes.sol";

/// @notice Customer exactness and slippage checks, independent of VM fee inversion.
library Amounts {
  error InvalidFillAmounts();
  error LimitExceeded();

  /// @notice Validate the actual collected input and paid output against the intent.
  /// @dev PricingMath supplies the independently computed pre-fee registers afterward.
  /// An inverse fee map alone cannot reconstruct the canonical bid on fee plateaus.
  function normalize(Trade memory trade, uint256 input, uint256 output) internal pure returns (FillAmounts memory a) {
    if (input == 0 || output == 0 || trade.amountSpecified == 0) revert InvalidFillAmounts();
    if (trade.mode == AmountMode.EXACT_IN) {
      if (input != trade.amountSpecified) revert InvalidFillAmounts();
      if (output < trade.limitAmount) revert LimitExceeded();
    } else {
      if (output != trade.amountSpecified) revert InvalidFillAmounts();
      if (input > trade.limitAmount) revert LimitExceeded();
    }
    a.traderIn = input;
    a.traderOut = output;
    a.routerIn = input;
    a.routerOut = output;
  }
}
