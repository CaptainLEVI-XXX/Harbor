// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "@1inch/swap-vm/src/libs/MakerTraits.sol";
import {Salt} from "@1inch/swap-vm/src/instructions/Controls.sol";
import {Jump, JumpIfTokenIn} from "@1inch/swap-vm/src/instructions/Jumps.sol";
import {FeeProtocol} from "@1inch/swap-vm/src/instructions/FeeProtocol.sol";
import {HarborPricing} from "src/swapvm/instructions/HarborPricing.sol";

/// @title HarborProgram
/// @notice Canonical bidirectional Aqua order using official Extruction and FeeProtocol.
/// @dev Requires the pinned Aqua router instruction set; no private opcode slots.
/// This builder grants no registration authority. The vault publishes through Aqua.ship.
library HarborProgram {
  /// @notice A token or authority address is zero, or the pair is degenerate.
  error InvalidConfiguration();

  /// @notice Build the one canonical bidirectional program for an approved route.
  /// @dev Version is also the uint64 salt. Book verifies receipt admission and live custody.
  function build(
    address vault,
    address book,
    address cashAsset,
    address base,
    uint256 route,
    uint256 version,
    address recipient,
    uint256 feeBps
  ) public pure returns (ISwapVM.Order memory) {
    if (version == 0 || version > type(uint64).max) revert InvalidConfiguration();
    return _build(vault, book, cashAsset, base, route, version, recipient, feeBps);
  }

  function _build(
    address vault,
    address book,
    address cashAsset,
    address base,
    uint256 route,
    uint256 version,
    address recipient,
    uint256 feeBps
  ) private pure returns (ISwapVM.Order memory order) {
    if (
      vault == address(0) || book == address(0) || vault == book || cashAsset == address(0) || base == address(0)
        || cashAsset == base
    ) revert InvalidConfiguration();
    MakerTraitsLib.Args memory args;
    args.maker = vault;
    (args.tokenA, args.tokenB) = cashAsset < base ? (cashAsset, base) : (base, cashAsset);
    args.useAquaInsteadOfSignature = true;
    args.hasPostTransferInHook = true;
    args.hasPreTransferOutHook = true;
    args.hasPostTransferOutHook = true;
    args.postTransferInTarget = book;
    args.preTransferOutTarget = book;
    args.postTransferOutTarget = book;
    // build is the sole caller and proves 0 < version <= uint64.max.
    // The salt and pricing instruction must share this one version source.
    bytes memory prefix = Salt.build(uint64(version));
    bytes memory core = HarborPricing.build(book, route, version);
    if (feeBps == 0) {
      args.program = bytes.concat(prefix, core);
    } else {
      if (feeBps > 100 || recipient == address(0)) revert InvalidConfiguration();
      FeeProtocol.ReceiverConfig[] memory receivers = new FeeProtocol.ReceiverConfig[](1);
      receivers[0] = FeeProtocol.ReceiverConfig(recipient, uint24(feeBps * 1000), 0);
      FeeProtocol.ProviderConfig[] memory providers = new FeeProtocol.ProviderConfig[](0);
      bytes memory buy = bytes.concat(FeeProtocol.build(false, receivers, providers, 0), core);
      bytes memory sell = bytes.concat(FeeProtocol.build(true, receivers, providers, 0), core);
      // These two jumps are dispatched by the pinned Aqua router; JumpIfDirection is not.
      uint256 sellPC = prefix.length + JumpIfTokenIn.build(cashAsset, 0).length + buy.length + Jump.build(0).length;
      uint256 endPC = sellPC + sell.length;
      if (endPC > type(uint16).max) revert InvalidConfiguration();
      args.program =
        bytes.concat(prefix, JumpIfTokenIn.build(cashAsset, uint16(sellPC)), buy, Jump.build(uint16(endPC)), sell);
    }
    return MakerTraitsLib.build(args);
  }
}
