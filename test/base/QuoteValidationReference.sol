// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {FixedPointMathLib as Math} from "solady/utils/FixedPointMathLib.sol";
import {Side, Trade, AmountMode} from "src/types/HarborTypes.sol";
import {SwapQuery} from "@1inch/swap-vm/src/libs/VM.sol";
import {HarborPricing} from "src/swapvm/instructions/HarborPricing.sol";

/// @title QuoteValidationReference
/// @notice Deterministic amount and public-price guards on authenticated inputs.
library QuoteValidationReference {
  error PublicPriceViolation();
  error InvalidPricePolicy();
  error InvalidQuote();

  /// @notice Bind canonical fixed-width intent bytes to the VM's actual order and direction.
  /// @dev Fixed linked code reads the Book's canonical order hash and validates
  /// encoding; Book separately authenticates the caller and transaction phase.
  function intent(
    SwapQuery calldata query,
    mapping(uint256 => bytes32) storage hashes,
    bytes calldata args,
    bytes calldata payload
  ) public view returns (Trade memory trade, bytes32 context) {
    (uint256 route, uint256 version) = HarborPricing.parse(args);
    if (payload.length != 13 * 32) revert InvalidQuote();
    trade = abi.decode(payload, (Trade));
    context = keccak256(payload);
    if (
      context != keccak256(abi.encode(trade)) || route != trade.route || version != trade.strategyVersion
        || query.orderHash != hashes[route] || query.tokenIn != trade.tokenIn || query.tokenOut != trade.tokenOut
        || query.isExactIn != (trade.mode == AmountMode.EXACT_IN)
    ) revert InvalidQuote();
  }

  /// @notice Bound gross purchase debit or net resale receipt in settlement-asset raw units.
  /// @param entitlement Verified entitlement for the exact base quantity, settlement-asset raw units.
  /// @param multiplier Bid/ask in 1e18 scale.
  /// @param buffer Nonnegative ASSET adjustment, applied against the maker's spend.
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
