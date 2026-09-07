// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";

/// @title DeployHarbor
/// @notice Local-only immutable deployment with reproducible CREATE bindings.
/// @dev Use a configured Foundry account/sender; no private key is read or logged.
/// Live deployment stays gated pending issuer, valuation and independent review.
contract DeployHarbor is Script {
  error LiveDeploymentGated();
  error DeploymentMismatch();

  function run(HarborBook.Config memory config, RouteConfig[] memory routes, uint256 minSeed, uint256 minRequest)
    external
    returns (HarborBook book, HarborVault vault, HarborExecutor executor)
  {
    if (block.chainid != 31337) revert LiveDeploymentGated();
    address deployer = msg.sender;
    uint64 nonce = vm.getNonce(deployer);
    address expectedBook = vm.computeCreateAddress(deployer, nonce);
    config.vault = vm.computeCreateAddress(deployer, nonce + 1);
    config.executor = vm.computeCreateAddress(deployer, nonce + 2);
    vm.startBroadcast(deployer);
    book = new HarborBook(config, routes);
    vault = new HarborVault(config.weth, address(book), config.maxMarkAge, config.depositCap, minSeed, minRequest);
    executor = new HarborExecutor(address(book), address(vault), config.router, config.weth);
    vm.stopBroadcast();
    if (
      address(book) != expectedBook || address(vault) != config.vault || address(executor) != config.executor
        || address(book.VAULT()) != address(vault) || address(book.EXECUTOR()) != address(executor)
        || address(vault.BOOK()) != address(book) || address(executor.BOOK()) != address(book)
        || executor.VAULT() != address(vault) || address(book).code.length > 24_576
        || address(vault).code.length > 24_576 || address(executor).code.length > 24_576
    ) revert DeploymentMismatch();
  }
}
