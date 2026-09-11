// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/base/IssuerFixture.sol";

/// @notice Production adapter marks, distinct publisher, synthetic issuer finalization.
abstract contract NativeValuationFixture is IssuerFixture {
  function _nativeRoutes() internal pure override returns (uint256) {
    return 1;
  }

  function _markPublisher() internal pure override returns (address) {
    return address(0x0ba5e);
  }
}
