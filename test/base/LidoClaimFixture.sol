// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LidoFixture} from "test/base/LidoFixture.sol";
import {HarborClaimReceipt} from "src/claims/HarborClaimReceipt.sol";
import {HarborClaimFactory} from "src/claims/HarborClaimFactory.sol";
import {ClaimImport, CollateralKind} from "src/types/ClaimTypes.sol";

/// @notice Adversarial issuer/custody fixtures; none of these mutations are fork evidence.
abstract contract LidoClaimFixture is LidoFixture {
  HarborClaimReceipt internal receipt;
  uint256 internal id;
  address internal holder = address(0xa11ce);

  function setUp() public virtual override {
    super.setUp();
    factory.schedule(address(adapter));
    vm.warp(vm.getBlockTimestamp() + 1 days);
    factory.activate(address(adapter));
    base.mint(holder, 2 ether);
    vm.startPrank(holder);
    base.approve(address(queue), 2 ether);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1 ether;
    id = queue.requestWithdrawalsWstETH(amounts, holder)[0];
    queue.approve(address(adapter), id);
    receipt = HarborClaimReceipt(
      factory.wrap(address(adapter), ClaimImport(CollateralKind.ERC721, address(queue), id, 1, ""), holder)
    );
    vm.stopPrank();
  }
}
