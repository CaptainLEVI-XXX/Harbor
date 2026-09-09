// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/base/IssuerFixture.sol";

/// @notice One deployment-size gate; not a transaction gas benchmark.
contract ExecutionGasTest is IssuerFixture {
  function test_DeployedRuntimeSizes() public {
    assertLe(address(book).code.length, 24_576);
    assertLe(address(router).code.length, 24_576);
    assertLe(address(vault).code.length, 24_576);
    assertLe(address(executor).code.length, 24_576);
    assertLe(address(adapter).code.length, 24_576);
    vm.snapshotValue("HarborRuntimeBytes", "book", address(book).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "router", address(router).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "vault", address(vault).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "executor", address(executor).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "lido-adapter", address(adapter).code.length);
  }
}
