// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";

/// @title HarborSwapVMRouter
/// @notice Deployment alias for the pinned official AquaSwapVMRouter.
/// @dev Uses the upstream instruction set, with Extruction targeting the Book.
contract HarborSwapVMRouter is AquaSwapVMRouter {
  constructor(address aqua, address wrappedNative, address owner, string memory name, string memory version)
    AquaSwapVMRouter(aqua, wrappedNative, owner, name, version)
  {}
}
