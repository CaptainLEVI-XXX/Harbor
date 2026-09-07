// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {LidoFixture} from "test/helpers/LidoFixture.sol";
import {AdapterBase} from "src/adapters/base/AdapterBase.sol";
import {IHarborAdapter} from "src/interfaces/IHarborAdapter.sol";

contract LidoAdapterTest is LidoFixture {
  uint256 private activeId;

  function test_RequestTracksRealStatusAndClearsAllowance() public {
    uint256 id = _request(1 ether);
    assertTrue(adapter.accepted(id));
    assertEq(queue.ownerOf(id), address(adapter));
    assertEq(base.balanceOf(address(adapter)), 0);
    assertEq(base.allowance(address(adapter), address(queue)), 0);
    assertEq(weth.balanceOf(vault), 0);
  }

  function test_UnderlyingBoundsNotWrappedBounds() public {
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 900 ether; // 1080 underlying ETH: too large despite <1000 wrapped.
    base.mint(address(adapter), amounts[0]);
    vm.expectRevert(AdapterBase.InvalidRequest.selector);
    adapter.request(amounts, 0);
    amounts[0] = 83; // floor(83 * 1.2) = 99, below 100 underlying wei.
    vm.expectRevert(AdapterBase.InvalidRequest.selector);
    adapter.request(amounts, 0);
  }

  function test_EightSplitRequestsReturnIndividualEntitlements() public {
    uint256[] memory amounts = new uint256[](8);
    for (uint256 i; i < 8; ++i) {
      amounts[i] = 1 ether;
    }
    base.mint(address(adapter), 8 ether);
    IHarborAdapter.Request[] memory requests = adapter.request(amounts, 0);
    for (uint256 i; i < 8; ++i) {
      assertEq(requests[i].id, i + 1);
      assertEq(requests[i].shares, 1 ether);
      assertEq(requests[i].entitlement, 1.2 ether);
    }
    vm.expectRevert(AdapterBase.InvalidRequest.selector);
    adapter.request(new uint256[](9), 0);
  }

  function test_UnsolicitedBalancesCannotSubsidizeRequest() public {
    base.mint(address(adapter), 1 ether);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 1 ether;
    vm.expectRevert(AdapterBase.ReceiptMismatch.selector);
    adapter.request(amounts, 1 ether); // Book observed donation, but no typed funding.
    _request(1 ether);
    assertEq(base.balanceOf(address(adapter)), 1 ether);
  }

  function test_MalformedIssuerRequestRollsBack() public {
    uint256[] memory amounts = new uint256[](2);
    amounts[0] = amounts[1] = 1 ether;
    base.mint(address(adapter), 2 ether);
    for (uint256 fault = 1; fault <= 3; ++fault) {
      queue.setFault(fault);
      vm.expectRevert();
      adapter.request(amounts, 0);
      assertEq(queue.nextId(), 0);
      assertEq(base.balanceOf(address(adapter)), 2 ether);
      assertEq(base.allowance(address(adapter), address(queue)), 0);
      assertFalse(adapter.accepted(1));
    }
  }

  function test_RecoveryWrapsOnlyAttributedETHAndKeepsFixedBeneficiary() public {
    uint256 id = _request(1 ether);
    vm.deal(address(adapter), 7 ether); // Forced/pre-existing ETH is quarantined.
    weth.mint(address(adapter), 9 ether);
    queue.setFinalized(id, 1.19 ether);
    (uint256 cash, uint256 remaining) = adapter.claim(id, 1);
    assertEq(cash, 1.19 ether);
    assertEq(remaining, 0);
    assertEq(weth.balanceOf(vault), cash);
    assertEq(weth.balanceOf(address(adapter)), 9 ether);
    assertEq(address(adapter).balance, 7 ether);
    assertTrue(adapter.closed(id));
    vm.expectRevert(AdapterBase.InvalidRequest.selector);
    adapter.claim(id, 1);
  }

  function test_ZeroRecoveryStillClosesVerifiedExtinguishedRight() public {
    uint256 id = _request(1 ether);
    queue.setFinalized(id, 0);
    (uint256 cash, uint256 remaining) = adapter.claim(id, 1);
    assertEq(cash, 0);
    assertEq(remaining, 0);
    assertTrue(adapter.closed(id));
  }

  function test_NotFinalizedWrongHintAndChangedOwnershipFail() public {
    uint256 id = _request(1 ether);
    vm.expectRevert(AdapterBase.InvalidRequest.selector);
    adapter.claim(id, 1);
    queue.setFinalized(id, 1.2 ether);
    vm.expectRevert();
    adapter.claim(id, 2);
    queue.setOwner(id, address(1));
    vm.expectRevert(AdapterBase.InvalidRequest.selector);
    adapter.claim(id, 1);
    assertFalse(adapter.closed(id));
  }

  function test_ShortReceiptAndLiveRightCannotBeMarkedClosed() public {
    uint256 id = _request(1 ether);
    queue.setFinalized(id, 1.2 ether);
    for (uint256 fault = 4; fault <= 5; ++fault) {
      queue.setFault(fault);
      vm.expectRevert(AdapterBase.ReceiptMismatch.selector);
      adapter.claim(id, 1);
      assertFalse(adapter.closed(id));
      assertEq(weth.balanceOf(vault), 0);
      assertEq(queue.ownerOf(id), address(adapter));
    }
  }

  function test_OnlyBookAndNoUntrackedClaimsOrNFTCallbacks() public {
    uint256 id = _request(1 ether);
    vm.prank(address(7));
    vm.expectRevert(AdapterBase.Unauthorized.selector);
    adapter.claim(id, 1);
    vm.prank(address(7));
    vm.expectRevert(AdapterBase.Unauthorized.selector);
    adapter.request(new uint256[](1), 0);
    vm.expectRevert(AdapterBase.InvalidRequest.selector);
    adapter.claim(id + 1, 1);
    (bool ok,) = address(adapter)
      .call(
        abi.encodeWithSignature(
          "onERC721Received(address,address,uint256,bytes)", address(this), address(this), id, bytes("")
        )
      );
    assertFalse(ok);
    vm.deal(address(this), 1 ether);
    (ok,) = address(adapter).call{value: 1}("");
    assertFalse(ok);
  }

  function test_ReentrancyFromIssuerThroughAuthorizedBookIsBlocked() public {
    activeId = _request(1 ether);
    queue.setFinalized(activeId, 1.2 ether);
    queue.setCallback(address(this));
    adapter.claim(activeId, 1);
    assertFalse(queue.callbackSucceeded());
    assertEq(weth.balanceOf(vault), 1.2 ether);
  }

  function reenter() external {
    adapter.claim(activeId, 1);
  }
}
