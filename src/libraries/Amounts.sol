// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Side, AmountMode, Trade, FillAmounts} from "src/types/HarborTypes.sol";
import {Fees} from "src/libraries/Fees.sol";

/// @title Amounts
/// @notice Validates trader limits and maps all four modes onto router registers.
library Amounts {
  /// @notice Zero legs, nonminimal gross input, or mismatched exact-size instruction.
  error InvalidFillAmounts();
  /// @notice Actual input/output breaches the caller's minimum-output/maximum-input limit.
  error LimitExceeded();

  /// @notice Normalize an exact authorized pair; this does not authenticate it.
  /// @param trade Trader instruction, with net exact-output semantics.
  /// @param input Actual collected input, not the full exact-output input cap.
  /// @param output Actual net payout to the trader.
  /// @param bps Fee rate; a deployment's tighter fee cap is checked by its Book.
  /// @return a Exact normalized amounts and WETH fee.
  function normalize(Trade memory trade, uint256 input, uint256 output, uint256 bps)
    internal
    pure
    returns (FillAmounts memory a)
  {
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
    if (trade.side == Side.BUY_BASE) {
      a.routerIn = input;
      a.routerOut = Fees.grossForNet(output, bps);
      a.fee = a.routerOut - output;
    } else {
      a.routerIn = Fees.net(input, bps);
      a.routerOut = output;
      a.fee = input - a.routerIn;
      if (a.routerIn == 0) revert InvalidFillAmounts();
      if (trade.mode == AmountMode.EXACT_OUT && Fees.grossForNet(a.routerIn, bps) != input) {
        revert InvalidFillAmounts();
      }
    }
  }
}
