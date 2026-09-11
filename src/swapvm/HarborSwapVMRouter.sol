// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";

/// @title HarborSwapVMRouter
/// @notice Deployment alias for the pinned official AquaSwapVMRouter.
/// @dev No dispatch, quote, fee or transfer overrides. Harbor pricing runs via
/// official Extruction targeting its Book. A verified compatible official router
/// can also be supplied at deployment; an arbitrary newer ABI is not compatible.
contract HarborSwapVMRouter is AquaSwapVMRouter {
  constructor(address aqua, address wrappedNative, address owner, string memory name, string memory version)
    AquaSwapVMRouter(aqua, wrappedNative, owner, name, version)
  {}
}
