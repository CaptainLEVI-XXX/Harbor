// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Context} from "@1inch/swap-vm/src/libs/VM.sol";
import {IHarborClaim, IHarborClaimFactory} from "src/interfaces/IHarborClaim.sol";

/// @title HarborClaimGuard
/// @notice Verify one canonical pending right after exact amounts are established.
/// @dev Local opcode 0x56. No register, storage or taker-argument mutation. The
/// preceding authorization and all transfers revert if any guard fails.
library HarborClaimGuard {
  uint8 internal constant OPCODE = 0x56;
  uint8 internal constant ARGS_LENGTH = 96;

  error InvalidClaim();

  /// @notice Encode ABI words for receipt, factory and the publication's factory version.
  function build(address receipt, address factory, uint256 version) internal pure returns (bytes memory) {
    return abi.encodePacked(OPCODE, ARGS_LENGTH, abi.encode(receipt, factory, version));
  }

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
      c.FACTORY() != factory || !f.isReceipt(receipt) || f.receiptOf(c.REQUEST_ID()) != receipt
        || c.ISSUER() != f.ISSUER() || c.WETH() != f.WETH() || c.CHAIN_ID() != block.chainid || f.version() != version
        || c.status() != IHarborClaim.Status.PENDING
        || (buy
            ? (tokenOut != c.WETH() || amountIn != 1 || !f.active())
            : (tokenOut != receipt || tokenIn != c.WETH() || amountOut != 1))
    ) revert InvalidClaim();
  }

  /// @notice Read maker arguments only; static quote evaluation uses the same checks.
  function exec(Context memory ctx, bytes calldata args) internal view {
    if (args.length != ARGS_LENGTH) revert InvalidClaim();
    (address receipt, address factory, uint256 version) = abi.decode(args, (address, address, uint256));
    check(receipt, factory, version, ctx.query.tokenIn, ctx.query.tokenOut, ctx.swap.amountIn, ctx.swap.amountOut);
  }
}
