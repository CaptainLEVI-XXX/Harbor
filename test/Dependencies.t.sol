// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {AquaSwapVMRouter} from "@1inch/swap-vm/src/routers/AquaSwapVMRouter.sol";

/// @title DependenciesTest
/// @notice Verifies that the pinned upstream contracts compile and deploy together.
/// @dev Dependency wiring only; this does not exercise token settlement.
contract DependenciesTest is Test {
  function test_DeployOfficialAquaRouter() public {
    Aqua aqua = new Aqua();
    // Constructor wiring does not require a live WETH contract.
    address weth = makeAddr("weth");
    AquaSwapVMRouter router = new AquaSwapVMRouter(address(aqua), weth, address(this), "Harbor", "1");

    assertEq(address(router.AQUA()), address(aqua));
    assertEq(address(router.WETH()), weth);
    assertEq(router.owner(), address(this));
  }
}
