// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LidoFixture} from "test/base/LidoFixture.sol";
import {LidoClaimReceipt} from "src/claims/LidoClaimReceipt.sol";
import {LidoClaimFactory} from "src/claims/LidoClaimFactory.sol";

/// @notice Adversarial issuer/custody fixtures; none of these mutations are fork evidence.
abstract contract LidoClaimFixture is LidoFixture {
  LidoClaimFactory internal factory;
  LidoClaimReceipt internal receipt;
  uint256 internal id;
  address internal holder = address(0xa11ce);

  function setUp() public virtual override {
    super.setUp();
    factory = new LidoClaimFactory(address(queue), address(weth), address(this));
    base.mint(holder, 2 ether);
    vm.startPrank(holder);
    base.approve(address(queue), 2 ether);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1 ether;
    id = queue.requestWithdrawalsWstETH(amounts, holder)[0];
    queue.approve(address(factory), id);
    receipt = LidoClaimReceipt(payable(factory.wrap(id)));
    vm.stopPrank();
  }
}
