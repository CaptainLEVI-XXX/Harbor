// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {HarborSwapVMRouter} from "src/swapvm/HarborSwapVMRouter.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {LidoViews} from "src/adapters/lido/LidoViews.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";

/// @notice Local-only immutable deployment with checked CREATE bindings.
/// @dev No private keys, automatic admission or timestamp manipulation. Factory
/// and Book governors separately approve the adapter after their real delays;
/// publishers then submit independent marks/prices and governance ships strategies.
/// Linked libraries are resolved by Foundry. Never use the direct test harness here.
contract DeployHarbor is Script {
  struct LidoConfig {
    address queue;
    address factory; // Zero deploys a new shared factory; otherwise reuse.
    address markPublisher;
    uint256 minSeed;
    uint256 minRequest;
  }

  struct Deployment {
    HarborBook book;
    HarborVault vault;
    HarborExecutor executor;
    LidoAdapter adapter;
    HarborClaimFactory factory;
  }

  error LiveDeploymentGated();
  error DeploymentMismatch();

  /// @notice Core-only deployment for callers that already arranged adapter bindings.
  function run(HarborBook.Config memory config, RouteConfig[] memory routes, uint256 minSeed, uint256 minRequest)
    external
    returns (HarborBook book, HarborVault vault, HarborExecutor executor)
  {
    _local();
    vm.startBroadcast(msg.sender);
    (book, vault, executor) = _core(msg.sender, config, routes, minSeed, minRequest);
    vm.stopBroadcast();
  }

  /// @notice Deploy one Lido pool; optionally reuse Aqua, Router, Executor and factory.
  /// @dev Shared dependencies precede Book/Vault/adapter address prediction.
  /// config.vault and route.adapter are derived; a supplied Executor is verified.
  function runLido(HarborBook.Config memory config, RouteConfig memory route, LidoConfig memory lido)
    external
    returns (Deployment memory d)
  {
    _local();
    address deployer = msg.sender;
    vm.startBroadcast(deployer);
    if (config.aqua == address(0)) config.aqua = address(new Aqua());
    if (config.router == address(0)) {
      config.router = address(new HarborSwapVMRouter(config.aqua, config.asset, config.governor, "Harbor", "2"));
    }
    d.factory = lido.factory == address(0)
      ? new HarborClaimFactory(config.asset, config.governor, config.governanceDelay)
      : HarborClaimFactory(lido.factory);
    if (d.factory.ASSET() != config.asset) revert DeploymentMismatch();
    if (config.executor == address(0)) config.executor = address(new HarborExecutor(config.router, config.governor));
    // Two CREATE transactions and the Executor registration transaction consume
    // three sender nonces before adapter creation under startBroadcast.
    address expectedAdapter = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);
    route.adapter = expectedAdapter;
    RouteConfig[] memory routes = new RouteConfig[](1);
    routes[0] = route;
    (d.book, d.vault, d.executor) = _core(deployer, config, routes, lido.minSeed, lido.minRequest);
    d.adapter = new LidoAdapter(
      address(d.book),
      address(d.vault),
      route.base,
      config.asset,
      lido.queue,
      LidoViews.Config(
        address(d.factory), config.governor, lido.markPublisher, config.maxMarkAge, config.governanceDelay
      )
    );
    vm.stopBroadcast();
    if (
      address(d.adapter) != expectedAdapter || d.book.route(0).adapter != address(d.adapter)
        || d.adapter.BOOK() != address(d.book) || d.adapter.VAULT() != address(d.vault)
        || d.adapter.FACTORY() != address(d.factory)
    ) revert DeploymentMismatch();
    _size(address(d.adapter));
    _size(address(d.factory));
    _size(d.factory.IMPLEMENTATION());
  }

  function _core(
    address deployer,
    HarborBook.Config memory config,
    RouteConfig[] memory routes,
    uint256 minSeed,
    uint256 minRequest
  ) private returns (HarborBook book, HarborVault vault, HarborExecutor executor) {
    if (config.executor == address(0)) {
      config.executor = address(new HarborExecutor(config.router, config.governor));
    }
    executor = HarborExecutor(config.executor);
    if (address(executor.ROUTER()) != config.router || executor.GOVERNOR() != deployer) revert DeploymentMismatch();
    uint64 nonce = vm.getNonce(deployer);
    address expectedBook = vm.computeCreateAddress(deployer, nonce);
    config.vault = vm.computeCreateAddress(deployer, nonce + 1);
    book = new HarborBook(config, routes);
    vault = new HarborVault(config.asset, address(book), config.maxMarkAge, minSeed, minRequest);
    executor.registerPool(address(book));
    if (
      address(book) != expectedBook || address(vault) != config.vault || address(executor) != config.executor
        || address(book.VAULT()) != address(vault) || address(book.EXECUTOR()) != address(executor)
        || address(vault.BOOK()) != address(book) || executor.vaultOf(address(book)) != address(vault)
    ) revert DeploymentMismatch();
    _size(address(book));
    _size(address(vault));
    _size(address(executor));
    _size(config.router);
  }

  function _size(address target) private view {
    if (target.code.length == 0 || target.code.length > 24_576) revert DeploymentMismatch();
  }

  function _local() private view {
    if (block.chainid != 31337) revert LiveDeploymentGated();
  }
}
