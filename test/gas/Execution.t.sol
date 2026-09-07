// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IssuerFixture} from "test/helpers/IssuerFixture.sol";
import {ISwapVM} from "@1inch/swap-vm/src/interfaces/ISwapVM.sol";
import {Trade, FillTerms, Side, AmountMode} from "src/types/HarborTypes.sol";

/// @notice Fixture-relative EVM execution snapshots, excluding quote generation.
/// @dev Uses synthetic marks, permits and issuer finalization. Not transaction total
/// gas, CRE delivery cost, a live token benchmark, or a production fee estimate.
contract ExecutionGasTest is IssuerFixture {
  function test_GasBuyExactInput() public {
    _trade(Side.BUY_BASE, AmountMode.EXACT_IN, "buy-exact-input-cold", false);
  }

  function test_GasBuyExactOutput() public {
    _trade(Side.BUY_BASE, AmountMode.EXACT_OUT, "buy-exact-output-cold", false);
  }

  function test_GasSellExactInput() public {
    _trade(Side.SELL_BASE, AmountMode.EXACT_IN, "sell-exact-input-cold", false);
  }

  function test_GasSellExactOutput() public {
    _trade(Side.SELL_BASE, AmountMode.EXACT_OUT, "sell-exact-output-cold", false);
  }

  function test_GasBuyAfterStaticPreflight() public {
    _trade(Side.BUY_BASE, AmountMode.EXACT_IN, "buy-exact-input-preflight-warm", true);
  }

  function _trade(Side side, AmountMode mode, string memory name, bool preflight) private {
    if (side == Side.SELL_BASE) _buy(0, 2 ether);
    (Trade memory t, FillTerms memory f, bytes memory sig, ISwapVM.Order memory order) = _quote(0, side, mode, 1 ether);
    _cool();
    if (preflight) executor.quoteFill(t, f, sig, order);
    vm.prank(trader);
    vm.startSnapshotGas("HarborExecution", name);
    executor.execute(t, f, sig, order);
    vm.stopSnapshotGas();
    assertTrue(book.usedQuoteNonce(f.epoch, f.nonce));
  }

  function test_GasDeposit() public {
    weth.mint(alice, 1 ether);
    vm.prank(alice);
    weth.approve(address(vault), 1 ether);
    _cool();
    vm.prank(alice);
    vm.startSnapshotGas("HarborExecution", "deposit-cold");
    vault.deposit(1 ether, alice);
    vm.stopSnapshotGas();
  }

  function test_GasEightTicketFunding() public {
    uint256 shares = vault.balanceOf(alice) / 16;
    for (uint256 i; i < 8; ++i) {
      vm.prank(alice);
      vault.requestRedeem(shares, alice, alice);
    }
    _cool();
    vm.startSnapshotGas("HarborExecution", "fund-eight-tickets-cold");
    vault.fulfillWithdrawals(8);
    vm.stopSnapshotGas();
    assertEq(vault.pendingRedeemRequest(0, alice), 0);
  }

  function test_GasFundedLPClaim() public {
    uint256 shares = vault.balanceOf(alice) / 2;
    vm.prank(alice);
    vault.requestRedeem(shares, alice, alice);
    vault.fulfillWithdrawals(1);
    uint256 units = vault.claimableRedeemRequest(0, alice);
    _cool();
    vm.prank(alice);
    vm.startSnapshotGas("HarborExecution", "funded-lp-claim-cold");
    vault.redeem(units, alice, alice);
    vm.stopSnapshotGas();
  }

  function test_GasEightIssuerRequests() public {
    _buy(0, 2 ether);
    uint256[] memory amounts = _amounts();
    // Intent construction is outside the measured scope.
    bytes memory callData = abi.encodeCall(book.requestRedemption, (_intent(amounts), amounts));
    _cool();
    vm.startSnapshotGas("HarborExecution", "request-eight-issuer-rights-cold");
    (bool ok, bytes memory result) = address(book).call(callData);
    vm.stopSnapshotGas();
    assertTrue(ok, string(result));
  }

  function test_GasEightIssuerRecoveries() public {
    _buy(0, 2 ether);
    uint256[] memory amounts = _amounts();
    book.requestRedemption(_intent(amounts), amounts);
    uint256[] memory ids = new uint256[](8);
    uint256[] memory hints = new uint256[](8);
    for (uint256 i; i < 8; ++i) {
      ids[i] = i + 1;
      hints[i] = 1;
      queue.setFinalized(ids[i], 0.12 ether);
    }
    _cool();
    vm.startSnapshotGas("HarborExecution", "recover-eight-issuer-rights-cold");
    book.claimRedemptions(0, ids, hints);
    vm.stopSnapshotGas();
    assertEq(book.getPosition(0).pendingBasis, 0);
  }

  function test_GasSixtyFourClaimCheckpoint() public {
    _buy(0, 8 ether);
    uint256[] memory amounts = _amounts();
    for (uint256 i; i < 8; ++i) {
      book.requestRedemption(_intent(amounts), amounts);
    }
    _cool();
    vm.startSnapshotGas("HarborExecution", "checkpoint-sixty-four-claims-cold");
    vault.checkpointValuation();
    vm.stopSnapshotGas();
    assertGt(vault.maxDeposit(alice), 0);
  }

  function test_GasStrategyRefresh() public {
    _cool();
    vm.startSnapshotGas("HarborExecution", "strategy-refresh-cold");
    vault.refreshStrategy(0);
    vm.stopSnapshotGas();
  }

  function test_DeployedRuntimeSizes() public {
    vm.snapshotValue("HarborRuntimeBytes", "book", address(book).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "router", address(router).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "vault", address(vault).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "executor", address(executor).code.length);
    vm.snapshotValue("HarborRuntimeBytes", "lido-adapter", address(adapter).code.length);
  }

  function _amounts() private pure returns (uint256[] memory a) {
    a = new uint256[](8);
    for (uint256 i; i < 8; ++i) {
      a[i] = 0.1 ether;
    }
  }

  function _cool() private {
    vm.cool(address(book));
    vm.cool(address(vault));
    vm.cool(address(executor));
    vm.cool(address(aqua));
    vm.cool(address(router));
    vm.cool(address(weth));
    vm.cool(address(bases[0]));
    vm.cool(address(bases[1]));
    vm.cool(address(valuation));
    vm.cool(address(policy));
    vm.cool(address(adapter));
    vm.cool(address(queue));
  }
}
