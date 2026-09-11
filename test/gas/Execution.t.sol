// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {NativeValuationFixture} from "test/base/NativeValuationFixture.sol";
import {DirectSettlementChecks} from "test/base/DirectSettlementChecks.sol";
import {DeployHarbor} from "script/DeployHarbor.s.sol";
import {PrimitiveChecks} from "test/base/PrimitiveChecks.sol";
import {BookExecution} from "src/libraries/BookExecution.sol";

/// @notice Deployment-size gate and warm exact-input execution comparison.
contract ExecutionGasTest is NativeValuationFixture {
  function test_DeployedRuntimeSizes() public {
    (uint256 optimizedHashGas, uint256 referenceHashGas) = new PrimitiveChecks().hashGas(0x1234);
    emit log_named_uint("64 scratch claim hashes gas", optimizedHashGas);
    emit log_named_uint("64 ABI reference hashes gas", referenceHashGas);
    assertLt(optimizedHashGas, referenceHashGas);
    // Exercise script nonce ordering and shared dependency reuse in the local EVM.
    DeployHarbor script = new DeployHarbor();
    DeployHarbor.Deployment memory deployed = script.runLido(
      deploymentConfig,
      book.route(0),
      DeployHarbor.LidoConfig(address(queue), address(factory), address(0xba5e), 1e12, 1e6)
    );
    assertEq(deployed.book.AQUA(), address(aqua));
    assertEq(deployed.book.ROUTER(), address(router));
    assertEq(address(deployed.executor), address(executor));
    assertEq(address(deployed.factory), address(factory));
    assertFalse(factory.active(address(deployed.adapter)));
    assertEq(deployed.vault.totalSupply(), 0);
    // Also exercise creation of shared dependencies before pool nonce prediction.
    deploymentConfig.aqua = address(0);
    deploymentConfig.router = address(0);
    deploymentConfig.executor = address(0); // A different Router requires its own shared Executor.
    deployed = script.runLido(
      deploymentConfig, book.route(0), DeployHarbor.LidoConfig(address(queue), address(0), address(0xba5e), 1e12, 1e6)
    );
    assertNotEq(deployed.book.AQUA(), address(aqua));
    assertNotEq(deployed.book.ROUTER(), address(router));
    assertNotEq(address(deployed.factory), address(factory));
    assertFalse(deployed.factory.active(address(deployed.adapter)));
    assertLe(address(book).code.length, 24_576);
    assertLe(address(BookExecution).code.length, 24_576);
    assertLe(address(router).code.length, 24_576);
    assertLe(address(vault).code.length, 24_576);
    assertLe(address(executor).code.length, 24_576);
    assertLe(address(adapter).code.length, 24_576);
    assertLe(address(factory).code.length, 24_576);
    assertLe(factory.IMPLEMENTATION().code.length, 24_576);
    vm.snapshotValue("HarborRuntimeBytes", "book", address(book).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "book-execution", address(BookExecution).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "router", address(router).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "vault", address(vault).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "executor", address(executor).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "lido-adapter", address(adapter).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "claim-factory", address(factory).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "claim-receipt", factory.IMPLEMENTATION().code.length);
    uint256 snapshot = vm.snapshotState();
    (uint256[4] memory gasUsed, uint256[4] memory coldGas) = new DirectSettlementChecks().measure();
    vm.revertToState(snapshot);
    uint256[4] memory claims = [uint256(0), 1, 8, 64];
    for (uint256 i; i < claims.length; ++i) {
      emit log_named_uint("held receipts", claims[i]);
      emit log_named_uint("Executor entrypoint gas", gasUsed[i]);
      emit log_named_uint("Executor cooled entrypoint gas", coldGas[i]);
    }
  }
}
