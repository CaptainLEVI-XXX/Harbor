// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LidoFixture} from "test/helpers/LidoFixture.sol";
import {LidoClaimReceipt} from "src/claims/LidoClaimReceipt.sol";
import {LidoClaimFactory} from "src/claims/LidoClaimFactory.sol";
import {IHarborClaim} from "src/interfaces/IHarborClaim.sol";

/// @notice Adversarial issuer/custody fixtures; none of these mutations are fork evidence.
abstract contract LidoClaimFixture is LidoFixture {
  LidoClaimFactory internal factory;
  LidoClaimReceipt internal receipt;
  uint256 internal id;
  address internal holder = address(0xa11ce);
  address internal buyer = address(0xb0b);
  bool internal attackSucceeded;
  uint256 internal attack;

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

contract LidoClaimSecurityTest is LidoClaimFixture {
  function test_TransferChangesOnlyRecoveryOwner() public {
    vm.prank(holder);
    receipt.transfer(buyer, 1);
    queue.setFinalized(id, 1.1 ether);
    receipt.recover(1);
    vm.prank(holder);
    vm.expectRevert();
    receipt.redeem(holder);
    vm.prank(buyer);
    receipt.redeem(buyer);
    assertEq(weth.balanceOf(buyer), 1.1 ether);
    assertEq(receipt.totalSupply(), 0);
    vm.expectRevert();
    receipt.recover(1);
    vm.prank(buyer);
    vm.expectRevert();
    receipt.redeem(buyer);
  }

  function test_RecordedCashFollowsReceiptTransferredAfterRecovery() public {
    queue.setFinalized(id, 1 ether);
    receipt.recover(1);
    vm.prank(holder);
    receipt.transfer(buyer, 1);
    vm.prank(buyer);
    receipt.redeem(buyer);
    assertEq(weth.balanceOf(holder), 0);
    assertEq(weth.balanceOf(buyer), 1 ether);
  }

  function test_ForeignCallbacksAndSecondActivationFail() public {
    vm.expectRevert();
    receipt.onERC721Received(address(factory), holder, id, "");
    vm.prank(address(queue));
    vm.expectRevert();
    receipt.onERC721Received(address(factory), holder, id, "");
    vm.prank(address(factory));
    vm.expectRevert();
    receipt.activate();
    vm.prank(address(factory));
    vm.expectRevert();
    receipt.initialize(id + 1, buyer);
    vm.prank(buyer);
    vm.expectRevert();
    receipt.initialize(id + 1, buyer);
    vm.deal(address(this), 1 ether);
    (bool ok,) = address(receipt).call{value: 1}("");
    assertFalse(ok);
    vm.expectRevert();
    factory.originate(1 ether);
  }

  function test_DonationsNeverBecomeHolderRecovery() public {
    vm.deal(address(receipt), 7 ether);
    weth.mint(address(receipt), 9 ether);
    queue.setFinalized(id, 1.1 ether);
    receipt.recover(1);
    vm.prank(holder);
    receipt.redeem(holder);
    assertEq(weth.balanceOf(holder), 1.1 ether);
    assertEq(weth.balanceOf(address(receipt)), 9 ether);
    assertEq(address(receipt).balance, 7 ether);
  }

  function test_ShortRecoveryOrUnextinguishedRightRollsBack() public {
    queue.setFinalized(id, 1.2 ether);
    for (uint256 fault = 4; fault <= 5; ++fault) {
      queue.setFault(fault);
      vm.expectRevert();
      receipt.recover(1);
      assertEq(queue.ownerOf(id), address(receipt));
      assertEq(receipt.recovered(), 0);
      assertEq(weth.balanceOf(address(receipt)), 0);
    }
    queue.setFault(0);
    receipt.recover(1);
  }

  function test_WrongHintChangedCustodyAndOverEntitlementFail() public {
    vm.expectRevert();
    receipt.recover(1);
    queue.setFinalized(id, 1.3 ether);
    vm.expectRevert();
    receipt.recover(1);
    queue.setFinalized(id, 1.2 ether);
    vm.expectRevert();
    receipt.recover(2);
    queue.setOwner(id, buyer);
    vm.expectRevert();
    receipt.status();
  }

  function test_ZeroRecoveryBurnsWithoutConsumingDonations() public {
    weth.mint(address(receipt), 9 ether);
    queue.setFinalized(id, 0);
    receipt.recover(1);
    vm.prank(holder);
    assertEq(receipt.redeem(holder), 0);
    assertEq(receipt.totalSupply(), 0);
    assertEq(weth.balanceOf(address(receipt)), 9 ether);
  }

  function test_NoImplicitPermit2OrAccidentalBurn() public {
    address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    assertEq(receipt.allowance(holder, permit2), 0);
    vm.prank(permit2);
    vm.expectRevert();
    receipt.transferFrom(holder, buyer, 1);
    vm.prank(holder);
    vm.expectRevert();
    receipt.transfer(address(0), 1);
    vm.prank(holder);
    vm.expectRevert();
    receipt.transfer(address(receipt), 1);
    vm.prank(holder);
    vm.expectRevert();
    receipt.transfer(buyer, 2);
  }

  function test_IssuerCannotTransferApprovedReceiptDuringRecovery() public {
    vm.prank(holder);
    receipt.approve(address(this), 1);
    queue.setFinalized(id, 1 ether);
    queue.setCallback(address(this));
    attack = 1;
    receipt.recover(1);
    assertFalse(attackSucceeded);
    assertEq(receipt.balanceOf(holder), 1);
    assertEq(receipt.balanceOf(buyer), 0);
  }

  function test_IssuerCannotReenterRecovery() public {
    queue.setFinalized(id, 1 ether);
    queue.setCallback(address(this));
    receipt.recover(1);
    assertFalse(attackSucceeded);
    assertEq(receipt.recovered(), 1 ether);
  }

  function reenter() external {
    if (attack == 1) {
      (attackSucceeded,) = address(receipt).call(abi.encodeCall(receipt.transferFrom, (holder, buyer, 1)));
    } else {
      (attackSucceeded,) = address(receipt).call(abi.encodeCall(receipt.recover, (1)));
    }
  }

  function test_OnlyOwnerCanWrapAndFinalizedImportRollsBack() public {
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1 ether;
    vm.prank(holder);
    uint256 next = queue.requestWithdrawalsWstETH(amounts, holder)[0];
    vm.expectRevert();
    factory.wrap(next);
    vm.prank(holder);
    queue.approve(address(factory), next);
    queue.setFinalized(next, 1 ether);
    vm.prank(holder);
    vm.expectRevert();
    factory.wrap(next);
    assertEq(factory.receiptOf(next), address(0));
    assertEq(queue.ownerOf(next), holder);
  }
}
