// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/helpers/IssuerFixture.sol";

contract IssuerReentrancyTest is IssuerFixture {
  uint256 private checks;
  uint256 private navBefore;
  uint256 private supplyBefore;

  function test_IssuerCallbackCannotCrossBookOrVaultDomains() public {
    _buy(0, 1 ether);
    uint256 id = _request(1 ether);
    vault.checkpointValuation();
    navBefore = vault.totalAssets();
    supplyBefore = vault.totalSupply();
    queue.setFinalized(id, 1.2 ether);
    queue.setCallback(address(this));
    _claim(id);
    assertEq(checks, 6);
    assertTrue(queue.callbackSucceeded()); // Probe returned normally; nested calls failed.
    assertTrue(book.getClaim(address(adapter), id).closed);
  }

  function reenter() external {
    assertEq(vault.totalAssets(), navBefore);
    assertEq(vault.totalSupply(), supplyBefore);
    assertEq(vault.maxDeposit(alice), 0);
    bytes[] memory calls = new bytes[](4);
    calls[0] = abi.encodeCall(vault.checkpointValuation, ());
    calls[1] = abi.encodeWithSignature("deposit(uint256,address)", 1 ether, alice);
    calls[2] = abi.encodeCall(vault.fulfillWithdrawals, (1));
    calls[3] = abi.encodeWithSignature("transfer(address,uint256)", alice, 0);
    for (uint256 i; i < calls.length; ++i) {
      (bool entered,) = address(vault).call(calls[i]);
      assertFalse(entered);
      ++checks;
    }
    (bool ok,) = address(book).call(abi.encodeCall(book.stopTrading, ()));
    assertFalse(ok);
    ++checks;
    (ok,) = address(book).call(abi.encodeCall(book.revokeKeeper, ()));
    assertFalse(ok);
    ++checks;
  }
}
