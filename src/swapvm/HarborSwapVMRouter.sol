// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import {Context} from "@1inch/swap-vm/src/libs/VM.sol";
import {HarborExactFill} from "src/swapvm/instructions/HarborExactFill.sol";

/// @title HarborSwapVMRouter
/// @notice Official Aqua SwapVM settlement with one additional exact-fill opcode.
/// @dev All existing dispatch, Aqua accounting, taker limits, locks and transfer
/// machinery are inherited unchanged from the pinned upstream implementation.
/// This is a custom deployment, not the unmodified official router address.
contract HarborSwapVMRouter is AquaSwapVMRouter {
  /// @notice Capability identifier used to reject an incompatible router at deployment.
  /// @dev This is not a code-hash attestation; deployment provenance still matters.
  uint8 public constant HARBOR_EXACT_FILL_OPCODE = HarborExactFill.OPCODE;

  /// @notice Bind the official settlement dependencies and inherited rescue owner.
  /// @param aqua Official Aqua deployment.
  /// @param weth Wrapped native asset used by upstream unwrapping support.
  /// @param owner Upstream router rescue authority; never a Harbor vault authority.
  /// @param name Router EIP-712 domain name.
  /// @param version Router EIP-712 domain version.
  constructor(address aqua, address weth, address owner, string memory name, string memory version)
    AquaSwapVMRouter(aqua, weth, owner, name, version)
  {}

  /// @dev Add only the locally assigned slot; preserve every upstream dispatch branch.
  function _runOpcode(Context memory ctx, uint256 opcode, bytes calldata args) internal override {
    if (opcode == HarborExactFill.OPCODE) HarborExactFill.exec(ctx, args);
    else super._runOpcode(ctx, opcode, args);
  }
}
