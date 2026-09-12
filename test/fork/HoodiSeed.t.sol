// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SeedHarborHoodi} from "test/base/SeedHarborHoodi.s.sol";

/// @notice Real deployed Harbor/Aqua/Lido; LP ETH and governor impersonation are fork-only.
contract HoodiSeedWorkflowTest is Test {
  function testTwoNewLPsCheckpointFundingAndAquaBids() public {
    vm.createSelectFork("hoodi", 3_607_888);
    SeedHarborHoodi seed = new SeedHarborHoodi();
    address lp1 = vm.addr(0xA11CE);
    address lp2 = vm.addr(0xB0B);
    vm.setEnv("HOODI_LP1_PRIVATE_KEY", vm.toString(uint256(0xA11CE)));
    vm.setEnv("HOODI_LP2_PRIVATE_KEY", vm.toString(uint256(0xB0B)));
    vm.setEnv("HOODI_LP1_ADDRESS", vm.toString(lp1));
    vm.setEnv("HOODI_LP2_ADDRESS", vm.toString(lp2));
    vm.setEnv("HOODI_LP1_ASSETS_WEI", "10000000000000000");
    vm.setEnv("HOODI_LP2_ASSETS_WEI", "20000000000000000");
    vm.deal(lp1, 1 ether);
    vm.deal(lp2, 1 ether);
    assertEq(seed.VAULT().totalSupply(), 0);
    (,, bool fresh) = seed.VAULT().valuationIdentity();
    assertFalse(fresh); // Reproduce the observed stale-evidence issue.
    uint256 first = seed.fundLP1();
    uint256 second = seed.fundLP2();
    assertEq(first, 0.01 ether * 1e6);
    assertEq(second, 0.02 ether * 1e6);
    assertEq(seed.VAULT().balanceOf(lp1), first);
    assertEq(seed.VAULT().balanceOf(lp2), second);
    assertEq(IERC20(seed.WETH()).balanceOf(address(seed.VAULT())), 0.03 ether);
    assertEq(seed.VAULT().totalAssets(), 0.03 ether);
    assertEq(seed.VAULT().tradingCash(0), 0.03 ether);
    assertEq(lp1.balance, 0.99 ether); // Test calls do not charge transaction gas.
    vm.expectRevert(SeedHarborHoodi.NotNewLP.selector);
    seed.fundLP1();
    vm.startPrank(seed.BOOK().GOVERNOR());
    seed.VAULT().checkpointValuation();
    bytes32 hash = seed.VAULT().refreshStrategy(0);
    vm.stopPrank();
    assertEq(seed.BOOK().strategyHash(0), hash);
    assertEq(seed.BOOK().strategyVersion(0), 1);
    seed.verify(0.001 ether, 0.001 ether); // Both exact modes through deployed SwapVM.
    vm.chainId(1);
    vm.expectRevert(SeedHarborHoodi.WrongDeployment.selector);
    seed.fundLP1();
  }
}
