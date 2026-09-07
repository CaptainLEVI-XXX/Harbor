// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {SwapRegisters} from "@1inch/swap-vm/src/libs/VM.sol";

/// @title HarborExtruction
/// @notice Strict metadata decoding and complementary-register construction.
/// @dev Caller authentication, quote authority and capacity belong to the Book.
library HarborExtruction {
  /// @notice Metadata must contain exactly two ABI words.
  error InvalidMetadataLength(uint256 length);
  /// @notice An authorized pair is zero or differs from the specified register.
  error InvalidAmounts();

  /// @notice Decode immutable route and version, rejecting trailing bytes.
  function decode(bytes calldata data) internal pure returns (uint256 route, uint256 version) {
    if (data.length != 64) revert InvalidMetadataLength(data.length);
    return abi.decode(data, (uint256, uint256));
  }

  /// @notice Supply only the missing amount of an already authenticated pair.
  /// @param registers Original VM registers; balances must remain unchanged.
  /// @param exactIn Whether amountIn is the taker-specified register.
  /// @param amountIn Authorized router input, raw token units.
  /// @param amountOut Authorized router output, raw token units.
  /// @return result Registers with only the complementary amount changed.
  function complete(SwapRegisters calldata registers, bool exactIn, uint256 amountIn, uint256 amountOut)
    internal
    pure
    returns (SwapRegisters memory result)
  {
    if (
      amountIn == 0 || amountOut == 0 || (exactIn ? registers.amountIn != amountIn : registers.amountOut != amountOut)
    ) revert InvalidAmounts();
    result = registers;
    if (exactIn) result.amountOut = amountOut;
    else result.amountIn = amountIn;
  }
}
