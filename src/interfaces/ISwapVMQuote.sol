// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";

/// @notice Static view of the pinned router's quote selector, which is declared
/// non-view upstream because execution and quoting share an instruction engine.
/// @dev STATICCALL forbids persistent AND transient writes in every child frame.
interface ISwapVMQuote {
  function quote(ISwapVM.Order calldata order, uint256 amount, bytes calldata takerData)
    external
    view
    returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);
}
