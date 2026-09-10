// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import {Salt} from "@1inch/swap-vm/src/instructions/Controls.sol";
import {HarborPricing} from "src/swapvm/instructions/HarborPricing.sol";
import {HarborClaimGuard} from "src/swapvm/instructions/HarborClaimGuard.sol";

/// @title HarborProgram
/// @notice Canonical bidirectional Aqua order using the Harbor standing-pricing opcode.
/// @dev Requires HarborSwapVMRouter. Salt is upstream; pricing is custom.
/// This builder grants no registration authority. The vault publishes through Aqua.ship.
library HarborProgram {
  /// @notice A token or authority address is zero, or the pair is degenerate.
  error InvalidConfiguration();

  /// @notice Build a vault-owned order with explicit Book settlement hooks.
  /// @param vault Aqua maker and input recipient.
  /// @param book Extension and hook target, distinct from the vault.
  /// @param weth Quote token.
  /// @param base Non-rebasing wrapped inventory token.
  /// @param route Route identifier in the Book.
  /// @param version Immutable strategy version.
  /// @param salt Fresh publication salt; docked hashes cannot be reused.
  /// @return order Canonical order; Aqua identity is keccak256(abi.encode(order)).
  function build(address vault, address book, address weth, address base, uint256 route, uint256 version, uint64 salt)
    public
    pure
    returns (ISwapVM.Order memory order)
  {
    return _build(vault, book, weth, base, route, version, salt, bytes(""));
  }

  /// @notice Add a custody/status guard to the standing-pricing settlement program.
  function claim(
    address vault,
    address book,
    address weth,
    address receipt,
    uint256 route,
    uint256 version,
    address factory,
    uint256 factoryVersion
  ) public pure returns (ISwapVM.Order memory) {
    return _build(
      vault,
      book,
      weth,
      receipt,
      route,
      version,
      uint64(version),
      HarborClaimGuard.build(receipt, factory, factoryVersion)
    );
  }

  function _build(
    address vault,
    address book,
    address weth,
    address base,
    uint256 route,
    uint256 version,
    uint64 salt,
    bytes memory tail
  ) private pure returns (ISwapVM.Order memory order) {
    if (
      vault == address(0) || book == address(0) || vault == book || weth == address(0) || base == address(0)
        || weth == base
    ) revert InvalidConfiguration();
    MakerTraitsLib.Args memory args;
    args.maker = vault;
    (args.tokenA, args.tokenB) = weth < base ? (weth, base) : (base, weth);
    args.useAquaInsteadOfSignature = true;
    args.hasPostTransferInHook = true;
    args.hasPreTransferOutHook = true;
    args.hasPostTransferOutHook = true;
    args.postTransferInTarget = book;
    args.preTransferOutTarget = book;
    args.postTransferOutTarget = book;
    args.program = bytes.concat(Salt.build(salt), HarborPricing.build(book, route, version), tail);
    return MakerTraitsLib.build(args);
  }
}
