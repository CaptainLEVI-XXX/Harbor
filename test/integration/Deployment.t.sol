// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {DeployHarbor} from "script/DeployHarbor.s.sol";
import {HarborBook} from "src/book/HarborBook.sol";
import {HarborVault} from "src/vault/HarborVault.sol";
import {HarborExecutor} from "src/execution/HarborExecutor.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";
import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";
import {TradingFixture} from "test/helpers/TradingFixture.sol";

/// @title DeploymentTest
/// @notice Scripted CREATE ordering and immutable cross-contract bindings.
contract DeploymentTest is TradingFixture {
  function test_DeployedCodeRespectsEthereumSizeLimit() public view {
    // Solidity test deployments may bypass EIP-170; never infer deployability from new alone.
    assertLe(address(book).code.length, 24_576);
    assertLe(address(vault).code.length, 24_576);
    assertLe(address(executor).code.length, 24_576);
    assertLe(address(router).code.length, 24_576);
  }

  function test_ScriptBindsAllContractsWithoutInitialization() public {
    vm.chainId(31337);
    DeployHarbor deployment = new DeployHarbor();
    RouteConfig[] memory routes = new RouteConfig[](2);
    routes[0] = book.route(0);
    routes[1] = book.route(1);
    (HarborBook b, HarborVault v, HarborExecutor e) = deployment.run(deploymentConfig, routes, 1e12, 1e6);
    assertEq(address(b.VAULT()), address(v));
    assertEq(address(b.EXECUTOR()), address(e));
    assertEq(address(v.BOOK()), address(b));
    assertEq(address(e.BOOK()), address(b));
    assertEq(e.VAULT(), address(v));
    assertEq(v.maxDeposit(alice), 0); // No initial mark or automatically enabled LP flow.
  }

  function test_ScriptRejectsLiveChain() public {
    DeployHarbor deployment = new DeployHarbor();
    RouteConfig[] memory routes = new RouteConfig[](0);
    vm.chainId(1);
    vm.expectRevert(DeployHarbor.LiveDeploymentGated.selector);
    deployment.run(deploymentConfig, routes, 1e12, 1e6);
  }

  function test_RejectsRouterWithoutCustomInstruction() public {
    AquaSwapVMRouter upstream = new AquaSwapVMRouter(address(aqua), address(weth), address(this), "Harbor", "1");
    HarborBook.Config memory config = deploymentConfig;
    config.router = address(upstream);
    RouteConfig[] memory routes = new RouteConfig[](1);
    routes[0] = book.route(0);
    vm.expectRevert(); // The unmodified router has no Harbor instruction capability selector.
    new HarborBook(config, routes);
  }
}
