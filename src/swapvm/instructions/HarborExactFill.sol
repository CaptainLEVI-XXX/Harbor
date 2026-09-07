// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Context, ContextLib, SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";
import {IHarborFill, IHarborFillQuote} from "src/interfaces/IHarborFill.sol";

/// @title HarborExactFill
/// @notice A native SwapVM instruction for Book-authorized, indivisible fills.
/// @dev Opcode 0x55 occupies an unused swap-family slot in the pinned upstream
/// table. This assignment is local to HarborSwapVMRouter, not an upstream opcode.
/// Wire: [0x55:1][length=84:1][book:20][route:32][version:32].
/// The instruction consumes ALL remaining taker arguments. Instructions that
/// need taker data must precede it. Fee/amount transforms must not follow it in
/// Harbor's canonical program: settlement hooks bind the authorized exact pair.
library HarborExactFill {
  using ContextLib for Context;

  /*//////////////////////////////////////////////////////////////
                            CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @dev Local opcode assignment; upgrading upstream requires a collision check.
  uint8 internal constant OPCODE = 0x55;
  /// @dev Packed address plus two full-width ABI words.
  uint8 internal constant ARGS_LENGTH = 84;

  /*//////////////////////////////////////////////////////////////
                              ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Instruction arguments must have exactly the documented packed length.
  error InvalidArgumentsLength(uint256 length);
  /// @notice The instruction may not call a zero authority.
  error InvalidAuthority();
  /// @notice Both amounts must be positive and the specified register must match.
  error InvalidAmounts();

  /*//////////////////////////////////////////////////////////////
                             ENCODING
  //////////////////////////////////////////////////////////////*/

  /// @notice Encode a maker-committed exact-fill instruction.
  /// @param book Fixed authorization and settlement authority.
  /// @param route Route identifier, without narrowing.
  /// @param version Strategy version, without narrowing.
  /// @return instruction Header followed by exactly 84 argument bytes.
  function build(address book, uint256 route, uint256 version) internal pure returns (bytes memory instruction) {
    if (book == address(0)) revert InvalidAuthority();
    return abi.encodePacked(OPCODE, ARGS_LENGTH, book, route, version);
  }

  /// @notice Decode fixed-width packed arguments without allocating temporary bytes.
  /// @dev Safety considerations: exact length is checked before every load. The
  /// last word starts at byte 52 and ends at byte 84. The address is the first
  /// 20 bytes (right-shifted by 96); no dirty high bits reach the Solidity value.
  /// This block reads calldata only and neither touches memory nor storage.
  /// @param args Packed instruction arguments, excluding the two-byte header.
  /// @return book Maker-selected authorization authority.
  /// @return route Full-width route identifier.
  /// @return version Full-width strategy version.
  function parse(bytes calldata args) internal pure returns (address book, uint256 route, uint256 version) {
    if (args.length != ARGS_LENGTH) revert InvalidArgumentsLength(args.length);
    assembly ("memory-safe") {
      book := shr(96, calldataload(args.offset))
      route := calldataload(add(args.offset, 20))
      version := calldataload(add(args.offset, 52))
    }
    if (book == address(0)) revert InvalidAuthority();
  }

  /*//////////////////////////////////////////////////////////////
                             EXECUTION
  //////////////////////////////////////////////////////////////*/

  /// @notice Authorize the pair and compute only the complementary VM amount.
  /// @dev No router storage writes. Book writes on swap are reverted atomically
  /// if amount validation or any later transfer/hook fails. Quote authorization
  /// uses STATICCALL. Balances, query, fees and nextPC are never assigned here.
  /// @param ctx Official SwapVM context, passed by memory reference.
  /// @param args Maker-committed packed authority, route and version.
  function exec(Context memory ctx, bytes calldata args) internal {
    (address book, uint256 route, uint256 version) = parse(args);
    bytes calldata payload = ctx.takerArgs();
    uint256 amountIn;
    uint256 amountOut;
    if (ctx.vm.isStaticContext) {
      (amountIn, amountOut) = IHarborFillQuote(book).authorizeFill(true, ctx.query, route, version, payload);
    } else {
      (amountIn, amountOut) = IHarborFill(book).authorizeFill(false, ctx.query, route, version, payload);
    }
    complete(ctx.swap, ctx.query.isExactIn, amountIn, amountOut);
    ctx.tryChopTakerArgs(payload.length);
  }

  /// @notice Set only the unspecified amount; no rounding is performed here.
  /// @dev The Book has already verified fee normalization and quote rounding.
  /// @param registers VM amounts and balances, updated in place.
  /// @param exactIn True when amountIn is specified by the taker.
  /// @param amountIn Authorized input in raw token units.
  /// @param amountOut Authorized output in raw token units.
  function complete(SwapRegisters memory registers, bool exactIn, uint256 amountIn, uint256 amountOut) internal pure {
    if (
      amountIn == 0 || amountOut == 0 || (exactIn ? registers.amountIn != amountIn : registers.amountOut != amountOut)
    ) revert InvalidAmounts();
    if (exactIn) registers.amountOut = amountOut;
    else registers.amountIn = amountIn;
  }
}
