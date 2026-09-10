// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/base/IssuerFixture.sol";
import {MockTradingValuation} from "test/base/TradingFixture.sol";
import {MockLidoQueue} from "test/base/LidoFixture.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {LidoValuation} from "src/valuation/LidoValuation.sol";

/// @notice Real valuation, Book, vault and VM with synthetic issuer finalization.
/// @dev One admitted issuer. Predicted bindings are checked after CREATE, exactly
/// as immutable deployment requires. The cast only shares conversion() with the
/// generic fixture; this provider exposes none of its mock observation setters.
abstract contract NativeValuationFixture is IssuerFixture {
  function _nativeRoutes() internal pure override returns (uint256) {
    return 1;
  }

  function _deployValuation() internal override returns (MockTradingValuation) {
    queue = new MockLidoQueue(address(bases[0]));
    address expectedAdapter = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 4);
    LidoValuation marks = new LidoValuation(
      LidoValuation.Config(
        address(bases[0]), address(queue), expectedAdapter, address(this), address(0x0ba5e), 60, 1 days
      )
    );
    return MockTradingValuation(address(marks));
  }

  function _routeAdapter(uint256, uint64 nonce) internal view override returns (address) {
    return vm.computeCreateAddress(address(this), nonce + 3);
  }

  function _afterDeploy() internal override {
    adapter = new LidoAdapter(address(book), address(vault), address(bases[0]), address(weth), address(queue));
    assertEq(book.route(0).adapter, address(adapter));
    assertEq(LidoValuation(address(valuation)).ADAPTER(), address(adapter));
    vm.prank(address(0x0ba5e));
    LidoValuation(address(valuation)).publish(1e18, 1e18, 1000, 1060, 1);
    vm.deal(address(queue), 10000 ether);
  }
}
