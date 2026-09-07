// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SwapQuery} from "@1inch/swap-vm/src/libs/VM.sol";

/// @title IHarborFill
/// @notice Exact-fill authority called by Harbor's SwapVM instruction.
/// @dev The Book authenticates the router, maker, taker and shipped order. It
/// cannot return a program counter, change balances, or choose how many bytes
/// the instruction consumes. Amounts are raw token units, not prices.
interface IHarborFill {
  /// @notice Authorize an exact input/output pair for the current VM query.
  /// @param isStaticContext True for a write-free quote; false for nonce consumption.
  /// @param query Immutable order, participants, direction and amount mode.
  /// @param route Maker-committed route identifier.
  /// @param version Maker-committed strategy version.
  /// @param payload Canonical ABI encoding of Trade, FillTerms and signature.
  /// @return amountIn Authorized router input in tokenIn raw units.
  /// @return amountOut Authorized router output in tokenOut raw units.
  function authorizeFill(
    bool isStaticContext,
    SwapQuery calldata query,
    uint256 route,
    uint256 version,
    bytes calldata payload
  ) external returns (uint256 amountIn, uint256 amountOut);
}

/// @title IHarborFillQuote
/// @notice Static-call view of the same selector; not a second Book entrypoint.
/// @dev Declaring this interface view makes the compiler emit STATICCALL even
/// when the enclosing router quote is invoked through a non-static CALL.
interface IHarborFillQuote {
  /// @notice Read the authorized pair without consuming a nonce or writing context.
  /// @dev Parameters and returns have the same meaning as IHarborFill.authorizeFill.
  function authorizeFill(
    bool isStaticContext,
    SwapQuery calldata query,
    uint256 route,
    uint256 version,
    bytes calldata payload
  ) external view returns (uint256 amountIn, uint256 amountOut);
}
