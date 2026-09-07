// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TradingFixture} from "test/helpers/TradingFixture.sol";
import {MockWrappedEther, MockWstETH, MockLidoQueue} from "test/helpers/LidoFixture.sol";
import {TokenMock} from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import {LidoAdapter} from "src/adapters/LidoAdapter.sol";
import {RedeemIntent} from "src/types/HarborTypes.sol";

abstract contract IssuerFixture is TradingFixture {
  LidoAdapter internal adapter;
  MockLidoQueue internal queue;
  uint256 internal requestNonce;

  function _deployWeth() internal override returns (TokenMock) {
    return new MockWrappedEther();
  }

  function _deployBase(uint256 i) internal override returns (TokenMock) {
    return i == 0 ? new MockWstETH() : super._deployBase(i);
  }

  function _routeAdapter(uint256 i, uint64 nonce) internal override returns (address) {
    return i == 0 ? vm.computeCreateAddress(address(this), nonce + 4) : super._routeAdapter(i, nonce);
  }

  function _afterDeploy() internal override {
    queue = new MockLidoQueue(address(bases[0]));
    adapter = new LidoAdapter(address(book), address(vault), address(bases[0]), address(weth), address(queue));
    assertEq(book.route(0).adapter, address(adapter));
    vm.deal(address(queue), 10000 ether);
  }

  function _intent(uint256[] memory amounts) internal returns (RedeemIntent memory intent) {
    uint256 total;
    for (uint256 i; i < amounts.length; ++i) {
      total += amounts[i];
    }
    intent = RedeemIntent(
      block.chainid,
      address(vault),
      address(book),
      0,
      address(adapter),
      1,
      total,
      total * 12 / 10,
      amounts.length,
      book.getPosition(0).version,
      book.redemptionEpoch(),
      ++requestNonce,
      block.timestamp + 60,
      keccak256(abi.encode(amounts))
    );
  }

  function _request(uint256 amount) internal returns (uint256 id) {
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    id = book.requestRedemption(_intent(amounts), amounts)[0].id;
  }

  function _claim(uint256 id) internal {
    uint256[] memory ids = new uint256[](1);
    uint256[] memory hints = new uint256[](1);
    ids[0] = id;
    hints[0] = 1;
    vm.prank(address(0xc1a1));
    book.claimRedemptions(0, ids, hints);
  }
}
