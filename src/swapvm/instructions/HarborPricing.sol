// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Extruction} from "@1inch/swap-vm/src/instructions/Extruction.sol";
import {SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {Trade, Side, AmountMode} from "src/types/HarborTypes.sol";

/// @title HarborPricing
/// @notice Official Extruction encoding and strict core-register completion.
/// @dev The Book is the immutable pricing target. Native FeeProtocol surrounds
/// this extension; no private opcode number or replacement VM dispatcher is used.
library HarborPricing {
  error InvalidArgumentsLength(uint256 length);
  error InvalidAuthority();
  error InvalidAmounts();

  /// @notice Bind one Book, route and strategy version into the maker's program.
  function build(address book, uint256 route, uint256 version) internal pure returns (bytes memory) {
    if (book == address(0)) revert InvalidAuthority();
    return Extruction.build(book, abi.encode(route, version));
  }

  /// @notice Decode exactly two full-width ABI words, after upstream strips the target.
  /// @dev Solidity's decoder supplies the required behavior; no custom assembly.
  function parse(bytes calldata args) internal pure returns (uint256 route, uint256 version) {
    if (args.length != 64) revert InvalidArgumentsLength(args.length);
    return abi.decode(args, (uint256, uint256));
  }

  /// @notice Complete pre-fee amounts without modifying reserves or VM control.
  /// @param registers Registers normalized by the canonical FeeProtocol branch.
  /// @param t Authenticated original customer intent, not normalized cash amounts.
  /// @param input Core amountIn computed once from verified Book state.
  /// @param output Core amountOut computed once from verified Book state.
  /// @param bps Fixed Book fee, bounded at construction to at most 100 / 10,000.
  /// @param receipt True only for a Book-registered, verified whole-unit receipt.
  /// @dev Fee arithmetic is limited to indivisible cash-lot compatibility. For
  /// a BUY exact-out, floor fees can map two gross amounts to one net amount;
  /// permit a one-wei reduction only when canonical cash still pays the exact
  /// requested net. For a SELL exact-in, reject the second gross on a plateau:
  /// excess cash is not a donation. Generic asset trades never use these checks.
  function complete(
    SwapRegisters memory registers,
    Trade memory t,
    uint256 input,
    uint256 output,
    uint256 bps,
    bool receipt
  ) public pure returns (SwapRegisters memory) {
    if (input == 0 || output == 0) revert InvalidAmounts();
    bool exactIn = t.mode == AmountMode.EXACT_IN;
    if (receipt && t.side == Side.SELL_BASE && exactIn) {
      if (input + input * bps / (10_000 - bps) != t.amountSpecified) revert InvalidAmounts();
    }
    if (!exactIn && registers.amountOut != output) {
      if (
        !receipt || t.side != Side.BUY_BASE || registers.amountOut != output + 1
          || output - output * bps / 10_000 != t.amountSpecified
      ) revert InvalidAmounts();
    } else if (exactIn && registers.amountIn != input) {
      revert InvalidAmounts();
    }
    registers.amountIn = input;
    registers.amountOut = output;
    return registers;
  }
}
