// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {RedemptionMarketFixture} from "test/claims/RedemptionMarket.t.sol";
import {RouteConfig} from "src/types/HarborTypes.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice A public log replay can recover the exact issuer, admission and publication mandate.
contract ConfigurationEventsTest is RedemptionMarketFixture {
  function setUp() public override {}

  function test_DeploymentAndAdmissionEmitTheExactApprovedParameters() public {
    vm.recordLogs();
    super.setUp();
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 nativeRoutes;
    uint256 scheduled;
    uint256 activated;
    uint256 published;
    for (uint256 i; i < logs.length; ++i) {
      Vm.Log memory log = logs[i];
      if (log.emitter != address(book)) continue;
      if (
        log.topics[0]
          == keccak256(
            "IssuerRouteConfigured(uint256,address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
          )
      ) {
        RouteConfig memory r = book.route(uint256(log.topics[1]));
        assertEq(address(uint160(uint256(log.topics[2]))), r.base);
        assertEq(address(uint160(uint256(log.topics[3]))), r.adapter);
        assertEq(
          log.data,
          abi.encode(
            r.bid, r.ask, r.buyBuffer, r.sellBuffer, r.maxExposure, r.maxPurchases, r.lossBudget, r.maxDailyRedemption
          )
        );
        ++nativeRoutes;
      } else if (
        log.topics[0] == keccak256("ClaimIntegrationScheduled(address,uint256,address,address,uint256,uint256,uint256)")
      ) {
        assertEq(address(uint160(uint256(log.topics[1]))), address(factory));
        assertEq(uint256(log.topics[2]), 0);
        assertEq(
          log.data,
          abi.encode(address(queue), address(weth), 0.97e18, 0.98e18, book.claimIntegration(address(factory)).readyAt)
        );
        ++scheduled;
      } else if (log.topics[0] == keccak256("ClaimIntegrationStatusChanged(address,bool,bool,uint256)")) {
        assertEq(address(uint160(uint256(log.topics[1]))), address(factory));
        assertEq(log.data, abi.encode(true, false, book.quoteEpoch()));
        ++activated;
      } else if (log.topics[0] == keccak256("StrategyPublished(uint256,bytes32,uint256,uint256,uint256)")) {
        uint256 route = uint256(log.topics[1]);
        assertEq(log.topics[2], book.strategyHash(route));
        assertEq(log.data, abi.encode(book.strategyVersion(route), 0, ++published));
      }
    }
    assertEq(nativeRoutes, book.INVENTORY_ROUTES());
    assertEq(scheduled, 1);
    assertEq(activated, 1);
    assertEq(published, 2);
  }
}
